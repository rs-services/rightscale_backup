#
# Cookbook Name:: test-rightscale_backup
# Library:: helper
#
# Copyright (C) 2013 RightScale, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'mixlib/shellout'

# A collection of helper methods for testing `rightscale_volume` cookbook.
#
module RightscaleBackupTest
  module Helper
    # Initializes `right_api_client`.
    #
    # @return [RightApi::Client] the client instance
    #
    def initialize_api_client
      require 'right_api_client'
      require '/var/spool/cloud/user-data.rb'

      account_id, instance_token = ENV['RS_API_TOKEN'].split(':')
      api_url = "https://#{ENV['RS_SERVER']}"
      client = RightApi::Client.new({
        :account_id => account_id,
        :instance_token => instance_token,
        :api_url => api_url
      })
      client.log(Chef::Log.logger)
      client
    end

    # Gets the instance of the right_api_client if the client is initialized.
    # If client not initialized, this will initialize the client and return the instance.
    #
    # @return [RightApi::Client] the client instance
    #
    def api_client
      @@api_client ||= initialize_api_client
    end

    # Deletes volumes from the cloud.
    #
    # @param filter [Hash{Symbol => String}] the optional filters
    #
    def delete_volumes(filter = {})
      get_volumes(filter).each { |volume| volume.destroy }
    end

    # Delete backups from the cloud.
    #
    # @param lineage [String] the backup lineage
    # @param filter [Hash{Symbol => String}] the optional filters
    #
    def delete_backups(lineage, filter = {})
      get_backups(lineage, filter).each { |backup| backup.destroy }
    end

    # Detaches volumes from an instance.
    #
    def detach_volumes
      get_volume_attachments.each do |attachment|
        volume = attachment.volume
        attachment.destroy
        while ((status = volume.show.status) == 'in-use')
          Chef::Log.info "Waiting for volume to detach... Status is '#{status}'"
          sleep 5
        end
      end
    end

    # Gets the list of backups of a particular lineage on a cloud.
    #
    # @param lineage [String] the lineage of the backup
    # @param filter [Hash{Symbol => String}] the optional filters
    #
    # @return [Array<RightApi::Resource>] the backups found
    #
    def get_backups(lineage, filter = {})
      filter.merge!({:cloud_href => get_cloud_href})
      api_client.backups.index(:lineage => lineage, :filter => build_filters(filter))
    end

    # Gets the href of the cloud.
    #
    # @return [String] the cloud href
    #
    def get_cloud_href
      api_client.get_instance.links.detect { |link| link['rel'] == 'cloud' }['href']
    end

    # Gets the list of volumes from the cloud based on the filter.
    #
    # @param filter [Hash] the optional filter to query volumes
    # @see [Volume Resource](http://reference.rightscale.com/api1.5/resources/ResourceVolumes.html#index_filters)
    # for available filters
    #
    # @return [Array<RightApi::Resource>] the volumes found
    #
    def get_volumes(filter = {})
      api_client.volumes.index(:filter => build_filters(filter))
    end

    # Gets the volume attachments for a particular instance.
    #
    # @param filter [Hash{Symbol => String}] the optional filters
    #
    # @return [Array<RightApi::Resource>] the volume attachments found
    #
    def get_volume_attachments(filter = {})
      filter.merge!({:instance_href => api_client.get_instance.href})
      api_client.volume_attachments.index(:filter => build_filters(filter))
    end

    # Checks if the backup was created in the cloud.
    #
    # @param name [String] the backup name
    # @param lineage [String] the backup lineage
    #
    # @return [Boolean] true if backup was created, false otherwise
    #
    def is_backup_created?(name, lineage)
      filter = {
        "committed" => "true"
      }
      backups = get_backups(lineage, filter).map { |backup| backup.name }

      if backups.empty?
        return false
      else
        return true if backups.include?(name)
      end
      false
    end

    # Waits for backups to complete.
    #
    # @param lineage [String] the backup lineage
    #
    def wait_for_backups(lineage)
      backup = get_backups(lineage, "committed" => "true").first
      while (completed = backup.show.completed) != true
        Chef::Log.info "Waiting for backup to complete... Status is '#{completed}'"
        sleep 5
      end
    end

    # Checks if the volume is detached from an instance in the cloud.
    #
    # @param volume_id [String] the ID of the volume to be queried
    #
    # @return [Boolean] true if the volume is detached, false otherwise
    #
    def is_volume_detached?(volume_id)
      volume_to_be_detached = get_volumes(:resource_uid => volume_id).first
      return false if volume_to_be_detached.nil?
      filter = build_filters({
        :instance_href => api_client.get_instance.href,
        :volume_href => volume_to_be_detached.href
      })
      api_client.volume_attachments.index(:filter => filter).empty? ? true : false
    end

    # Checks if the volume is deleted from the cloud.
    #
    # @param volume_name [String] the name of the volume to be queried
    #
    # @return [Boolean] true if the volume is deleted, false otherwise
    #
    def is_volume_deleted?(volume_name)
      volumes_found = get_volumes(:name => volume_name)
      volumes_found.empty? ? true : false
    end

    # Builds filters in the format supported by API 1.5.
    #
    # @param filters [Hash] the filters
    #
    # @return [Array] the array of filters in the supported format
    #
    # @example Given filters as follows
    #
    # {
    #   :name => "some_name",
    #   :value => "!2",
    #   :foo => "<>something"
    #   :bar => "==foo"
    # }
    #
    # The output of this method will be
    #
    # ["name==some_name", "value<>2", "foo<>something", "bar==foo"]
    #
    def build_filters(filters)
      filters.map do |name, filter|
        case filter.to_s
        when /^(!|<>)(.*)$/
          operator = '<>'
          filter = $2
        when /^(==)?(.*)$/
          operator = '=='
          filter = $2
        end
        "#{name}#{operator}#{filter}"
      end
    end

    # Formats the device as ext3 and mounts it to a mount point.
    #
    # @param device [String] the device to be formatted and mounted
    # @param mount_point [String] the path where the device must be mounted
    #
    def format_and_mount_device(device, mount_point)
      Chef::Log.info "Formatting #{device} as ext3..."
      execute_command("mkfs.ext3 -F #{device}")

      Chef::Log.info "Mounting #{device} at #{mount_point}..."
      execute_command("mkdir -p #{mount_point}")
      execute_command("mount #{device} #{mount_point}")
    end

    # Unmounts device from the mount point.
    #
    # @param device [String] the device to be unmounted
    # @param mount_point [String] the path where the device must be mounted
    #
    def unmount_device(device, mount_point)
      Chef::Log.info "Unmounting #{device} from #{mount_point}"
      execute_command("umount #{mount_point}")
    end

    # Generates a random test file.
    #
    # @param mount_point [String] the path where the device must be mounted
    #
    def generate_test_file(mount_point)
      test_file = File.join(mount_point, 'test_file')
      Chef::Log.info "Generating random file into #{test_file}..."
      execute_command("dd if=/dev/urandom of=#{test_file} bs=16M count=8")
    end

    # Executes the given command.
    #
    # @param command [String] the command to be executed
    #
    def execute_command(command)
      command = Mixlib::ShellOut.new(command)
      command.run_command
      Chef::Log.debug command.stdout
      Chef::Log.debug command.stderr
      command.error!
    end
  end
end
