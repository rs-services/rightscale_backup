#
# Cookbook Name:: rightscale_backup
# Spec:: resource_rightscale_backup
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

require 'spec_helper'

describe Chef::Resource::RightscaleBackup do
  let(:resource) { Chef::Resource::RightscaleBackup.new('rightscale_backup', run_context) }
  let(:node) { Chef::Node.new }
  let(:events) { Chef::EventDispatch::Dispatcher.new }
  let(:run_context) { Chef::RunContext.new(node, {}, events) }

  it "has a resource_name called 'rightscale_backup'" do
    resource.resource_name.should == :rightscale_backup
  end

  context "attributes that can be set" do
    it "has a name attribute to set the name for the backup" do
      resource.name('test_backup')
      resource.name.should == 'test_backup'
    end

    it "has a lineage attribute to set backup lineage" do
      resource.lineage('test_lineage')
      resource.lineage.should == 'test_lineage'
    end

    it "has a description attribute to set the description for a backup" do
      resource.description('test backup description')
      resource.description.should == 'test backup description'
    end

    it "has a timestamp attribute to specify the backup to restore" do
      resource.timestamp(113456789)
      resource.timestamp.should == 113456789
    end

    it "has a devices attribute for specifying the devices to backup" do
      resource.devices(['some_device_1', 'some_device_2'])
      resource.devices.should be_a_kind_of(Array)
      resource.devices.should == ['some_device_1', 'some_device_2']
    end

    it "has a devices attribute which takes only arrays as an argument" do
      expect { resource.devices('abcd') }.to raise_error
    end

    it "has a from_master attribute to denote a backup was taken from a master" do
      resource.from_master.should be_false
    end

    it "has a from_master attribute which takes only boolean values" do
      expect { restore.from_master('true') }.to raise_error
    end

    it "has a size attribute to set the size for the volume during backup restore" do
      resource.size(10)
      resource.size.should == 10
    end

    it "has a size attribute which takes only integer values" do
      expect { resource.size('10') }.to raise_error
    end

    it "has attributes for setting backup rotation options" do
      resource.keep_last.should == 60
      resource.dailies.should == 1
      resource.weeklies.should == 4
      resource.monthlies.should == 12
      resource.yearlies.should == 2
    end

    it "has attributes for setting backup rotation options which takes only Integer" do
      expect { resource.keep_last('10') }.to raise_error
      expect { resource.dailies('10') }.to raise_error
      expect { resource.weeklies('10') }.to raise_error
      expect { resource.monthlies('10') }.to raise_error
      expect { resource.yearlies('10') }.to raise_error
    end

    it "has an options attribute to pass optional parameters like volume type" do
      resource.options({:key => 'value'})
      resource.options.should == {:key => 'value'}
    end

    it "has an options attribute which takes only hashes" do
      expect { resource.options('10') }.to raise_error
    end

    it "has an attribute called 'timeout'" do
      resource.timeout == 15
    end

    it "has a timeout attribute which takes only integer values" do
      expect { resource.max_snapshots('10') }.to raise_error
    end
  end
end
