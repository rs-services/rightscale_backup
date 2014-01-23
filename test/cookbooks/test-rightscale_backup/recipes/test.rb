#
# Cookbook Name:: test-rightscale_volume
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

include_recipe 'rightscale_volume::default'
include_recipe 'rightscale_backup::default'

# Include cookbook-delayed_evaluator for delaying evaluation of node attributes
# to converge phase instead of compile phase
include_recipe 'delayed_evaluator'

# Set minimum volume size to 100GB for Rackspace Open Clouds (cloud-specific feature)
volume_size = node['cloud']['provider'] == 'rackspace-ng' ? 100 : 1

# Set the volume name with the current UNIX timestamp so that multiple test runs
# do not overlap each other in case of failures
timestamp = Time.now.to_i
test_volume_1 = "test_device_1_#{timestamp}_DELETE_ME"
test_volume_2 = "test_device_2_#{timestamp}_DELETE_ME"

backup_1 = "test_backup_1_DELETE_ME"
backup_2 = "test_backup_2_DELETE_ME"
backup_lineage = "test_backup_lineage_#{timestamp}"

# *** Testing actions supported by the rightscale_backup cookbook ***

log '***** TESTING action_create - create backup of volume 1 and 2 *****'

# Create and attach volume 1 and 2 using the rightscale_volume cookbook
rightscale_volume test_volume_1 do
  size volume_size
  description "test device created from rightscale_volume cookbook"
  action [:create, :attach]
end

ruby_block 'mount volume and generate random test file' do
  block do
    format_and_mount_device(node['rightscale_volume'][test_volume_1]['device'])
    generate_test_file
  end
end

rightscale_volume test_volume_2 do
  size volume_size
  description "test device created from rightscale_volume cookbook"
  action [:create, :attach]
end

ruby_block 'mount volume and generate random test file' do
  block do
    format_and_mount_device(node['rightscale_volume'][test_volume_2]['device'])
    generate_test_file
  end
end

# Take a backup of volume 1 and 2
rightscale_backup backup_1 do
  lineage backup_lineage
  description "test backup created from rightscale_backup cookbook"
  devices lazy do
    devices = []
    node['rightscale_volume'].each { |name, attribute| devices.push(attribute['device']) }
    devices
  end
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

# Detach and delete volume 1 and 2
rightscale_volume test_volume_1 do
  action [:detach, :delete]
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
    if is_backup_restored?(backup_1) && get_volume_attachments.length == 2
      Chef::Log.info 'TESTING action_restore -- PASSED'
    else
      raise 'TESTING action_restore -- FAILED'
    end
  end
end

log '***** TESTING action_cleanup - delete old backups *****'

# Take a backup of one of the devices
rightscale_backup backup_2 do
  lineage backup_lineage
  description "test backup created from rightscale_backup cookbook"
  devices lazy do
    devices = []
    devices.push(node['rightscale_backup']['devices'].first)
    devices
  end
  action :create
end

# Ensure backup 2 was created
ruby_block "ensure backup #{backup_2} created" do
  block do
    if is_backup_created?(backup_2, backup_lineage)
      Chef::Log.info 'TESTING action_create -- PASSED'
    else 
      raise 'TESTING action_create -- FAILED'
    end
  end
end

# Clean up backups
rightscale_backup 'test_backup_DELETE_ME' do
  lineage "test_backup_lineage"
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
    else·
      raise 'TESTING action_cleanup -- FAILED'
    end
  end
end

# clean up everything
ruby_block "clean up resources created during the test" do
  block do
    delete_backups
    detach_volumes
    delete_volumes(:name => backup_1)
    delete_volumes(:name => test_volume_1)
    delete_volumes(:name => test_volume_2)
  end
end
