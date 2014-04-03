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
    # A Chef provider for the rightscale_backup resource.
    #
    class RightscaleBackup < Chef::Provider
      # Loads @current_resource instance variable with backup hash values in the
      # node if backup exists in the node. Also initializes right_api_client for
      # making instance-facing RightScale API calls.
      #
      def load_current_resource
        @new_resource.nickname(@new_resource.name) unless @new_resource.nickname
        @current_resource = Chef::Resource::RightscaleBackup.new(@new_resource.name)
        @current_resource.nickname @new_resource.nickname
        node.set['rightscale_backup'] ||= {}

        @api_client = initialize_api_client

        # From the node, get the list of devices to which the volumes are attached
        # TODO: We don't use this attribute anywhere at the moment. This attribute
        # is intended to be used in the +:create+ action at some point later.
        unless node['rightscale_backup'].empty?
          @current_resource.devices(node['rightscale_backup'][@current_resource.nickname]['devices'])
        end
        @current_resource.timeout(@new_resource.timeout) if @new_resource.timeout
        @current_resource
      end

      # Creates a backup of the volumes in the cloud.
      #
      def action_create
        Chef::Log.info "Creating backup of all volumes currently attached to the instance..."

        # Backup all volumes attached to the instance.
        # TODO: Have a 'device' attribute for rightscale_backup resource which specifies
        # what device to back up. At this moment, we backup all devices by default due
        # to issues with RightScale API Backup resource and the design of this cookbook.
        # See https://github.com/rightscale-cookbooks/rightscale_backup/issues/2
        backup = create_backup(get_volume_attachment_hrefs)

        Chef::Log.info "Backup for devices '#{backup.show.name}' created and committed successfully."
        @new_resource.updated_by_last_action(true)
      end

      # Restores a backup of volumes from the cloud on to an instance.
      #
      def action_restore
        # If no timestamp was specified get the latest backup for the lineage.
        # API 1.5 does not do an inclusive search for timestamp so
        # increment by 1
        timestamp = @new_resource.timestamp ? Time.at(@new_resource.timestamp + 1) : Time.now

        # Get backup for the specified lineage and timestamp
        backup = find_latest_backup(@new_resource.lineage, timestamp, @new_resource.from_master)
        if backup.nil?
          raise " No backups found in lineage '#{@new_resource.lineage}' within timestamp '#{timestamp}'!" +
            " Please check the lineage and/or timestamp and try again."
        end

        node.set['rightscale_backup'][@current_resource.nickname] ||= {}
        node.set['rightscale_backup'][@current_resource.nickname]['devices'] = []

        # If multiple volume snapshots are found in the backup
        multiple_snapshots = backup.volume_snapshots.size > 1

        updates = backup.volume_snapshots.sort_by { |snapshot| snapshot['position'].to_i }.each do |snapshot|
          size = @new_resource.size
          description = @new_resource.description
          options = @new_resource.options
          timeout = @new_resource.timeout

          # If there are more than one volume snapshots, the volume nicknames will be appended with the position
          # number else the volume nickname will simply be the backup nickname.
          volume_nickname = multiple_snapshots ? "#{@new_resource.nickname}_#{snapshot['position']}" : @new_resource.nickname

          r = rightscale_volume volume_nickname do
            size size if size
            description description if description
            snapshot_id snapshot['resource_uid']
            options options
            timeout timeout if timeout

            action :nothing
          end

          r.run_action(:create)
          r.run_action(:attach)

          node.set['rightscale_backup'][@current_resource.nickname]['devices'] <<
            node['rightscale_volume'][volume_nickname]['device']

          r.updated?
        end

        @new_resource.updated_by_last_action(updates.any?)
      end

      # Cleans up old backups from the cloud.
      #
      def action_cleanup
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

        @new_resource.updated_by_last_action(true)
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
          :cloud_href => get_cloud_href,
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
            :name => @new_resource.nickname,
            :volume_attachment_hrefs => attachment_hrefs
          }
        }

        unless @new_resource.description.nil? || @new_resource.description.empty?
          params[:backup][:description] = @new_resource.description
        end

        params[:backup][:from_master] = @new_resource.from_master

        # Call the API to create the backup.
        Chef::Log.info "Creating a backup with the following parameters: #{params.inspect}..."
        new_backup = @api_client.backups.create(params)

        unless ['google', 'gce', 'ec2'].include?(node['cloud']['provider'])
          Timeout::timeout(@current_resource.timeout * 60) do
            begin
              # Wait till the backup is complete.
              while (completed = new_backup.show.completed) != true
                Chef::Log.info "Waiting for backup to complete... Status is '#{completed}'"
                sleep 5
              end
            rescue Timeout::Error => e
              raise e, "Backup did not create within #{@current_resource.timeout * 60} seconds!"
            end
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
      # @param timestamp [Time] the timestamp
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

        # Add cloud href to the list of filters so we only get backups in the current cloud as we can't restore backups
        # from a different cloud.
        cloud_href = @api_client.get_instance.cloud.href
        filter << "cloud_href==#{cloud_href}"

        backup = @api_client.backups.index(:lineage => lineage, :filter => filter)
        backup.first
      end

      # Gets all supported devices from /proc/partitions.
      #
      # @return [Array<String>] the devices list.
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

      # Gets the href of the cloud.
      #
      # @return [String] the cloud href
      #
      def get_cloud_href
        @api_client.get_instance.links.detect { |link| link['rel'] == 'cloud' }['href']
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
      # @return [Array<String>] the volume attachment hrefs
      #
      def get_volume_attachment_hrefs
        attachments = @api_client.volume_attachments.index(:filter => ["instance_href==#{get_instance_href}"])

        # Reject attachments whose device parameter is set to 'unknown'. Also skip the boot disk on gce.
        attachments.reject! do |attachment|
          attachment.device == 'unknown' || attachment.resource_uid =~ /\/disks\/boot-/
        end
        attachments.map { |attachment| attachment.href }
      end

      # Gets href of a volume type for a given volume type name. This returns nil
      # for all clouds that does not support volume types. Currently only
      # Rackspace Open Cloud supports volume types.
      #
      # @param volume_type [String] the volume type name
      #
      # @return [String, nil] the volume type href
      #
      def get_volume_type_href(volume_type)
        case node['cloud']['provider']
        when "rackspace-ng"
          # Rackspace Open Cloud offers two types of devices - SATA and SSD
          volume_types = @api_client.volume_types.index

          # Set SATA as the default volume type for Rackspace Open Cloud
          volume_type = 'SATA' if volume_type.nil?
          volume_types.detect { |type| type.name.downcase == volume_type.downcase }.href
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
    end
  end
end
