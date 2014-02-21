#
# Cookbook Name:: test-rightscale_backup
# Recipe:: test
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

class Chef::Resource
  include RightscaleBackupTest::Helper
end

include_recipe 'rightscale_backup::default'

# Set minimum volume size to 100GB for Rackspace Open Clouds (cloud-specific feature)
volume_size = node['cloud']['provider'] == 'rackspace-ng' ? 100 : 1

# Set the volume name with the current UNIX timestamp so that multiple test runs
# do not overlap each other in case of failures
timestamp = Time.now.to_i

volume_name_prefix = "test_device_#{timestamp}_DELETE_ME"
test_volume_1 = "#{volume_name_prefix}_1"
test_volume_2 = "#{volume_name_prefix}_2"

backup_name_prefix = "test_backup_#{timestamp}_DELETE_ME"
backup_1 = "#{backup_name_prefix}_1"
backup_2 = "#{backup_name_prefix}_2"
backup_lineage = "#{backup_name_prefix}_lineage"

# *** Testing actions supported by the rightscale_backup cookbook ***

log '***** TESTING action_create - create backup of volume 1 and 2 *****'

# Create and attach volume 1 and 2 using the rightscale_volume cookbook
rightscale_volume test_volume_1 do
  size volume_size
  description "test device created from rightscale_volume cookbook"
  action [:create, :attach]
end

ruby_block "mount #{test_volume_1} and generate random test file" do
  block do
    format_and_mount_device(node['rightscale_volume'][test_volume_1]['device'], '/mnt/storage1')
    generate_test_file('/mnt/storage1')
  end
end

rightscale_volume test_volume_2 do
  size volume_size
  description "test device created from rightscale_volume cookbook"
  action [:create, :attach]
end

ruby_block "mount #{test_volume_2} and generate random test file" do
  block do
    format_and_mount_device(node['rightscale_volume'][test_volume_2]['device'], '/mnt/storage2')
    generate_test_file('/mnt/storage2')
  end
end

# Backup the volumes
rightscale_backup backup_1 do
  lineage backup_lineage
  description "test backup created from rightscale_backup cookbook"
  action :create
end

# Ensure that the backup was created in the cloud
ruby_block "ensure backup #{backup_1} created" do
  block do
    if is_backup_created?(backup_1, backup_lineage)
      Chef::Log.info 'TESTING action_create -- PASSED'
    else
      raise 'TESTING action_create -- FAILED'
    end
  end
end

# Take another backup for testing clean up action
rightscale_backup backup_2 do
  lineage backup_lineage
  description "test backup created from rightscale_backup cookbook"
  action :create
end

# Ensure that the backup was created in the cloud
ruby_block "ensure backup #{backup_2} created" do
  block do
    if is_backup_created?(backup_2, backup_lineage)
      Chef::Log.info 'TESTING action_create -- PASSED'
    else
      raise 'TESTING action_create -- FAILED'
    end
  end
end

ruby_block "ensure that the backup is complete" do
  block do
    wait_for_backups(backup_lineage)
  end
end

# Detach and delete volume 1 and 2
ruby_block "unmount #{test_volume_1}" do
  block do
    unmount_device(node['rightscale_volume'][test_volume_1]['device'], '/mnt/storage1')
  end
end

rightscale_volume test_volume_1 do
  action [:detach, :delete]
end

ruby_block "unmount #{test_volume_2}" do
  block do
    unmount_device(node['rightscale_volume'][test_volume_2]['device'], '/mnt/storage2')
  end
end

rightscale_volume test_volume_2 do
  action [:detach, :delete]
end

log '***** TESTING action_restore from backup - restore test_backup_DELETE_ME *****'

rightscale_backup backup_1 do
  lineage backup_lineage
  description "test device created from rightscale_backup cookbook"
  action :restore
end

# Ensure that 2 volumes were restored
ruby_block "ensure that 2 volumes with names #{backup_1} were restored" do
  block do
    if get_volume_attachments.length == 2
      Chef::Log.info 'TESTING action_restore -- PASSED'
    else
      raise 'TESTING action_restore -- FAILED'
    end
  end
end

log '***** TESTING action_cleanup - delete old backups *****'

# Clean up backups
# API 1.5 overrides "keep_last" to 1 if we pass "keep_last" as anything less than 1.
# Therefore, at least one backup (latest) in a lineage will exist after the
# clean up action.
rightscale_backup backup_1 do
  lineage backup_lineage
  keep_last 1
  dailies 0
  weeklies 0
  monthlies 0
  yearlies 0
  action :cleanup
end

# Ensure that the backups got cleaned up
ruby_block "ensure backups were cleaned up" do
  block do
    if get_backups(backup_lineage).length == 1
      Chef::Log.info 'TESTING action_cleanup -- PASSED'
    else
      raise 'TESTING action_cleanup -- FAILED'
    end
  end
end

# clean up everything
ruby_block "clean up resources created during the test" do
  block do
    Chef::Log.info "Deleting all backups in '#{backup_lineage}' lineage..."
    delete_backups(backup_lineage)
    Chef::Log.info "Detaching all volumes from the server..."
    detach_volumes
    Chef::Log.info "Deleting volumes named '#{backup_name_prefix}'..."
    delete_volumes(:name => backup_name_prefix)
    Chef::Log.info "Deleting volumes named '#{volume_name_prefix}'..."
    delete_volumes(:name => volume_name_prefix)
  end
end
