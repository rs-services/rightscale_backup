#
# Cookbook Name:: rightscale_backup
# Library:: provider_rightscale_backup
#
# Copyright (C) 2013 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "chef/provider"

class Chef
  class Provider
    class RightscaleBackup < Chef::Provider
      def load_current_resource
        @current_resource = Chef::Resource::RightscaleBackup.new(@new_resource.name)
        node.set['rightscale_backup'] ||= {}

        @api_client = initialize_api_client

        # From the node, get the list of devices to which the volumes are attached
        unless node['rightscale_backup'].empty?
          @current_resource.devices = node['rightscale_backup']['devices']
        end
        @current_resource.timeout = @new_resource.timeout if @new_resource.timeout
        @current_resource
      end

      # Creates a backup of the volumes in the cloud.
      #
      def action_create
        raise_backup_lineage_missing unless @new_resource.lineage

        # If the devices to be backed-up was specified in the resource, then
        # backup only those devices. Else, backup all devices attached to the server.
        devices = []
        if @new_resource.devices
          # Push device to the array if it is not in the array already
          devices |= @new_resource.devices
        else
          Chef::Log.info "No devices are specified! Backup will be created" +
            " for all volumes currently attached to the instance."
          devices = @current_resource.devices
        end

        if devices.empty?
          raise "No volumes are attached to this instance to backup!" +
            " Please create and attach a volume using the 'create' and 'attach'" +
            " actions of the 'rightscale_volume' resource before running backup."
        end

        backup = create_backup(get_volume_attachment_hrefs(devices))

        if backup.nil?
          raise "Backup for devices '#{devices.join(', ')}' was not created successfully!"
        else
          Chef::Log.info "Backup for devices '#{devices.join(', ')}' created and committed successfully."
          @new_resource.updated_by_last_action(true)
        end
      end

      # Restores a backup of volumes from the cloud on to an instance.
      #
      def action_restore
        raise_backup_lineage_missing unless @new_resource.lineage

        # If no timestamp was specified get the latest backup for the lineage.
        # API 1.5 does not do an inclusive search for timestamp so
        # increment by 1
        timestamp = @new_resource.timestamp ? Time.at(@new_resource.timestamp.to_i + 1) : Time.now

        # Get backup for the specified lineage and timestamp
        backup = find_latest_backup(@new_resource.lineage, timestamp, @new_resource.from_master)
        if backup.nil?
          raise " No backups found in lineage '#{@new_resource.lineage}' within timestamp '#{timestamp}'!" +
            " Please check the lineage and/or timestamp and try again."
        end

        devices_before_restore = get_current_devices
        restore_status = restore_backup(backup, @new_resource.options)

        if restore_status == 'completed'
          restored_devices = get_current_devices - devices_before_restore
          node.set['rightscale_backup']['devices'] = restored_devices
          Chef::Log.info "Backups were restored successfully to #{restored_devices.join(', ')}"
          @new_resource.updated_by_last_action(true)
        else
          raise "Backups were not restored successfully!"
        end
      end

      # Cleans up old backups from the cloud.
      #
      def action_cleanup
        raise_backup_lineage_missing unless @new_resource.lineage

        # Get values for the number of backups to clean up specified by the user
        # If no values are specified use the defaults
        cleanup_options = {
          :keep_last => @new_resource.keep_last,
          :dailies => @new_resource.dailies,
          :monthlies => @new_resource.monthlies,
          :weeklies => @new_resource.weeklies,
          :yearlies => @new_resource.yearlies
        }

        cleanup_backups(@new_resource.lineage, cleanup_options)
      end

    private

      # Cleans up old backups in a specific lineage.
      #
      # @param lineage [String] the lineage of the backup to clean up
      # @param cleanup_options [Hash{Symbol => String}] the options for clean up
      # @option cleanup_options [Integer] :keep_last the number of backups to keep
      # @option cleanup_options [Integer] :dailies the number of daily backups to keep
      # @option cleanup_options [Integer] :monthlies the number of monthly backups to keep
      # @option cleanup_options [Integer] :weeklies the number of weekly backups to keep
      # @option cleanup_options [Integer] :yearlies the number of yearly backups to keep
      #
      def cleanup_backups(lineage, cleanup_options)
        # Get the parameters required for cleaning up
        params = {
          :cloud_href => api_cloud_href,
          :lineage => lineage
        }
        params.merge!(cleanup_options)

        Chef::Log.info "Cleaning up backups with params #{params.inspect}..."
        @api_client.backups.cleanup(params)
      end

      # Creates a backup of the volumes under a specific lineage.
      #
      # @param attachment_hrefs [Array<String>] the hrefs of the attached volumes
      #   to be backed up
      #
      # @return [RightApi::Resource] the newly created backup
      #
      # @raise [Timeout::Error] if the backup is not created within the timeout value
      #
      def create_backup(attachment_hrefs)
        params = {
          :backup => {
            :lineage => @new_resource.lineage,
            :name => @new_resource.name,
            :volume_attachment_hrefs => attachment_hrefs
          }
        }

        unless @new_resource.description.nil? || @new_resource.description.empty?
          params[:description] = @new_resource.description
        end

        params[:from_master] = @new_resource.from_master unless @new_resource.from_master.nil?

        Timeout::timeout(@current_resource.timeout * 60) do
          begin
            # Call the API to create the backup.
            Chef::Log.info "Creating a backup with the following parameters: #{params.inspect}..."
            new_backup = @api_client.backups.create(params)

            # Wait till the backup is complete.
            while (completed = new_backup.show.completed) != true
              Chef::Log.info "Waiting for backup to complete... Status is '#{completed}'"
              sleep 2
            end
          rescue Timeout::Error => e
            raise e, "Backup did not create within #{@current_resource.timeout * 60} seconds!"
          end
        end

        # Update the backup by setting committed to true.
        Chef::Log.info "Backup completed. Committing the backup..."
        new_backup.update(:backup => {:committed => "true"})

        new_backup
      end

      # Gets the latest committed and completed backups for the given lineage and
      # timestamp.
      #
      # @param lineage [String] the backup lineage
      # @param timestamp [Integer] the timestamp in epoch seconds
      # @param from_master [Boolean] the flag to find only master backups
      #
      # @return [RightApi::ResourceDetail, nil] the backup found or nil
      #
      def find_latest_backup(lineage, timestamp, from_master = nil)
        filter = [
          "latest_before==#{timestamp.utc.strftime('%Y/%m/%d %H:%M:%S %z')}",
          "committed==true",
          "completed==true"
        ]
        filter << "from_master==#{from_master}" if from_master
        backup = @api_client.backups.index(:lineage => lineage, :filter => filter)
        backup.first
      end

      # Gets all supported devices from /proc/partitions.
      #
      # @return [Array] the devices list.
      #
      def get_current_devices
        # Read devices that are currently in use from the last column in /proc/partitions
        partitions = IO.readlines("/proc/partitions").drop(2).map { |line| line.chomp.split.last }

        # Eliminate all LVM partitions
        partitions = partitions.reject { |partition| partition =~ /^dm-\d/ }

        # Get all the devices in the form of sda, xvda, hda, etc.
        devices = partitions.select { |partition| partition =~ /[a-z]$/ }.sort.map { |device| "/dev/#{device}" }

        # If no devices found in those forms, check for devices in the form of sda1, xvda1, hda1, etc.
        if devices.empty?
          devices = partitions.select { |partition| partition =~ /[0-9]$/ }.sort.map { |device| "/dev/#{device}" }
        end

        devices
      end

      # Gets the instance href.
      #
      # @return [String] the instance href
      #
      def get_instance_href
        @instance_href ||= @api_client.get_instance.href
      end

      # Gets all volume attachment hrefs for the specified devices.
      #
      # @param devices [Array] the array of devices
      #
      # @return [Array<String>] the volume attachment hrefs
      #
      def get_volume_attachments(devices = [])
        attachments = @api_client.volume_attachments.index(:filter => ["instance_href==#{get_instance_href}"])

        attachments = attachments.select do |attachment|
          device = attachment.show.device
          next if device == 'unknown'
          devices.include?(device) unless devices.empty?
        end

        attachments.map { |attachment| attachment.show.href }
      end

      # Gets href of a volume_type.
      #
      # @param size [Integer] the volume size (used by CloudStack to select appropriate volume type)
      # @param options [Hash] the optional parameters required to choose volume type
      #
      # @return [String, nil] the volume type href
      #
      # @raise [RuntimeError] if the volume type could not be found for the requested size (on CloudStack)
      #
      def get_volume_type_href(size, options = {})
        case node['cloud']['provider']
        when "rackspace-ng"
          # Rackspace Open Cloud offers two types of devices - SATA and SSD
          volume_types = @api_client.volume_types.index

          # Set SATA as the default volume type for Rackspace Open Cloud
          options[:volume_type] = 'SATA' if options[:volume_type].nil?
          volume_type = volume_types.detect do |type|
            type.name.downcase == options[:volume_type].downcase
          end
          volume_type.href

        when "cloudstack"
          # CloudStack has the concept of a "custom" disk offering
          # Anything that is not a custom type is a fixed size.
          # If there is not a custom type, we will use the closest size which is
          # greater than or equal to the requested size.
          # If there are multiple custom volume types or multiple volume types
          # with the closest size, the one with the greatest resource_uid will
          # be used.
          # If the resource_uid is non-numeric (e.g. a UUID), the first returned
          # valid volume type will be used.
          volume_types = @api_client.volume_types.index
          custom_volume_types = volume_types.select { |type| type.size.to_i == 0 }

          if custom_volume_types.empty?
            volume_types.reject! { |type| type.size.to_i < size }
            minimum_size = volume_types.map { |type| type.size.to_i }.min
            volume_types.reject! { |type| type.size.to_i != minimum_size }
          else
            volume_types = custom_volume_types
          end

          if volume_types.empty?
            raise "Could not find a volume type that is large enough for #{size}"
          elsif volume_types.size == 1
            volume_type = volume_types.first
          elsif volume_types.first.resource_uid =~ /^[0-9]+$/
            Chef::Log.info "Found multiple valid volume types"
            Chef::Log.info "Using the volume type with the greatest numeric resource_uid"
            volume_type = volume_types.max_by { |type| type.resource_uid.to_i }
          else
            Chef::Log.info "Found multiple valid volume types"
            Chef::Log.info "Using the first returned valid volume type"
            volume_type = volume_types.first
          end

          if volume_type.size.to_i == 0
            Chef::Log.info "Found volume type that supports custom sizes:" +
              " #{volume_type.name} (#{volume_type.resource_uid})"
          else
            Chef::Log.info "Did not find volume type that supports custom sizes"
            Chef::Log.info "Using closest volume type: #{volume_type.name}" +
              " (#{volume_type.resource_uid}) which is #{volume_type.size} GB"
          end

          volume_type.href
        end
      end

      # Initializes API client for handling RightScale instance facing API 1.5 calls.
      #
      # @param options [Hash] the optional parameters to the client
      #
      # @return [RightApi::Client] the RightAPI client instance
      #
      def initialize_api_client(options = {})
        require "right_api_client"

        # Load RightScale information from 'user-data' file
        require "/var/spool/cloud/user-data.rb"

        account_id, instance_token = ENV["RS_API_TOKEN"].split(":")
        options = {
          :account_id => account_id,
          :instance_token => instance_token,
          :api_url => "https://#{ENV["RS_SERVER"]}"
        }.merge options

        client = RightApi::Client.new(options)
        client.log(Chef::Log.logger)
        client
      end

      # Raises a RuntimeError with an error message if backup lineage was not
      # provided in 'rightscale_backup' resource.
      #
      def raise_backup_lineage_missing
        raise "Backup lineage attribute is missing. Lineage is a required" +
          " attribute for all 'network_storage_backup' actions." +
          " Specify backup lineage and try again."
      end

      # Restores a given backup and waits for the restore to complete.
      #
      # @param backup [RightApi::ResourceDetail] the backup to be restored
      # @param options [Hash{Symbol => String}] the options for restore
      # @option options [String] :volume_type the volume type of the volume being
      #   restored
      # @option options [String] :iops the IOPS value (supported only in EC2 clouds)
      #
      # @return [String, nil] the restore status
      #
      # @raise [RestClient::Exception] rescue "Timeout waiting for attachment"
      # errors (504) and retry
      # @raise [RuntimeError] if restore failed
      # @raise [Timeout::Error] if restore did not complete within the timeout
      #
      def restore_backup(backup, options = {})
        params = {
          :instance_href => get_instance_href,
          :backup => {
            :name => @new_resource.name
          }
        }
        params[:backup][:description] = @new_resource.description if @new_resource.description
        params[:backup][:size] = @new_resource.size if @new_resource.size

        if options[:volume_type]
          volume_type_href = get_volume_type_href(@new_resource.size, options)
          params[:backup][:volume_type_href] = volume_type_href unless volume_type_href.nil?
        end

        restore_status = nil
        Timeout::timeout(@current_resource.timeout * 60) do
          begin
            # Restore API call returns a 'task' API resource
            # http://reference.rightscale.com/api1.5/resources/ResourceTasks.html
            Chef::Log.info "Restoring backup with the following parameters: #{params.inspect}..."
            restore = backup.restore(params)
          rescue RestClient::Exception => e
            if e.http_code == 504
              Chef::Log.warn "Timeout waiting for attachment - #{e.message}! Retrying..."
              sleep 2
              retry
            end
            raise e
          end

          # Wait for restore to complete
          begin
            # Summary attribute of 'task' resource will be in this format
            # "restore_status: Attach volumes to instance through API"
            # Example, "completed: Attach volumes to instance through API"
            # Restore status can be obtained from the first part of summary
            restore_status = restore.show.summary.split(": ").first
            while restore_status != "completed"
              raise "Restore failed with status '#{restore_status}'!" if restore_status == "failed"

              Chef::Log.info " Waiting for restore to complete... Status is #{restore_status}"
              sleep 2
              restore_status = restore.show.summary.split(": ").first
            end
          rescue RestClient::Exception => e
            if e.http_code == 504
              Chef::Log.warn "Timeout waiting for attachment - #{e.message}! Retrying..."
              sleep 2
              retry
            end
            raise e
          rescue Timeout::Error => e
            raise e, "Restore did not complete within #{@current_resource.timeout * 60} seconds!"
          end
        end

        restore_status
      end
    end
  end
end
