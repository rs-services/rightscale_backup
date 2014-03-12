#
# Cookbook Name:: rightscale_backup
# Spec:: provider_rightscale_backup
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
require 'provider_rightscale_backup'

describe Chef::Provider::RightscaleBackup do
  let(:provider) do
    provider = Chef::Provider::RightscaleBackup.new(new_resource, run_context)
    provider.stub(:initialize_api_client).and_return(client_stub)
    provider
  end

  let(:new_resource) { Chef::Resource::RightscaleBackup.new('test_backup') }
  let(:current_resource) { Chef::Resource::RightscaleVolume.new('test_backup') }
  let(:events) { Chef::EventDispatch::Dispatcher.new }
  let(:node) do
    node = Chef::Node.new
    node.set['rightscale_backup'] = {}
    node
  end
  let(:run_context) { Chef::RunContext.new(node, {}, events) }

  # Mock objects for the right_api_client
  let(:client_stub) do
    client = double('RightApi::Client', :log => nil)
    client.stub(:get_instance).and_return(instance_stub)
    client
  end

  let(:instance_stub) do
    instance = double('instance')
    instance.stub(
      :links => [{
        'rel' => 'cloud',
        'href' => 'some_cloud_href'
      }],
      :href => 'some_href'
    )
    instance
  end

  let(:backup_stub) do
    backup = double('backup')
    backup.stub(
      :name => 'test_backup',
      :description => 'test_backup description',
      :completed => true
    )
    backup
  end

  let(:backup_resource) { double('backups', :show => backup_stub, :update => nil) }

  let(:task_resource) { double('tasks', :show => task_stub) }

  let(:task_stub) { double('task', :summary => 'completed: restore completed') }

  let(:volume_attachment_resource) do
    attachment = double('volume_attachments')
    attachment.stub(
      :show => volume_attachment_stub,
      :destroy => nil
    )
    attachment
  end

  let(:volume_attachment_stub) do
    attachment = double('volume_attachment')
    attachment.stub(
      :state => 'available',
      :device => 'some_device',
      :href => 'some_href',
      :resource_uid => 'v-123456'
    )
    attachment
  end

  let(:boot_volume_attachment_stub) do
    attachment = double('volume_attachment')
    attachment.stub(
      :state => 'available',
      :device => 'some_device',
      :href => 'some_href',
      :resource_uid => 'projects/example.com:test/disks/boot-i-12345'
    )
    attachment
  end

  let(:volume_type_stub) do
    volume_type = double('volume_type')
    volume_type.stub(
      :name => 'some_name',
      :href => 'some_href',
      :resource_uid => 'some_id'
    )
    volume_type
  end

  describe "#load_current_resource" do
    context "when the backup does not exist in the node" do
      it "should return current_resource" do
        provider.load_current_resource
        provider.current_resource.devices.should be_nil
      end
    end

    context "when the backup exists in the node" do
      it "should get the devices in the backup" do
        node.set['rightscale_backup']['test_backup']['devices'] = ['device_1', 'device_2']
        provider.load_current_resource
        provider.current_resource.devices.should == ['device_1', 'device_2']
      end
    end
  end

  # Test all actions supported by the provider
  #
  describe "actions" do
    # Creates a test volume by stubbing out the create_volume method.
    #
    def create_test_volume
      provider.stub(:create_volume).and_return(volume_stub)
      volume_stub.stub(:status).and_return('available')
      run_action(:create)
    end

    # Attaches a test volume by stubbing out the attach_volume method.
    #
    def attach_test_volume
      provider.stub(:device_letter_exclusions => [])
      provider.stub(:get_next_device).and_return('some_device')
      provider.stub(:attach_volume).and_return('/dev/some_device')
      run_action(:attach)
      volume_stub.stub(:status).and_return('in-use')
    end

    # Runs the specified action.
    #
    def run_action(action_sym)
      provider.run_action(action_sym)
      provider.load_current_resource
    end


    before(:each) do
      provider.new_resource = new_resource
    end

    describe "#action_create" do
      context "given a backup lineage" do
        it "should create the backup" do
          new_resource.lineage('some_lineage')
          provider.should_receive(:get_volume_attachment_hrefs).and_return(['some_href'])
          provider.should_receive(:create_backup).and_return(backup_resource)
          run_action(:create)
        end
      end
    end

    describe "#action_restore" do
      context "given a backup lineage" do
        context "a backup is found in the lineage" do
          it "should restore the backup" do
            new_resource.name('test_backup')
            new_resource.lineage('some_lineage')
            provider.should_receive(:find_latest_backup).and_return(backup_stub)
            provider.stub(:get_current_devices).and_return(
              ['device_1', 'device_2'],
              ['device_1', 'device_2', 'device_3']
            )
            provider.should_receive(:restore_backup).and_return('completed')
            run_action(:restore)
            node['rightscale_backup'][new_resource.name]['devices'].should == ['device_3']
          end

          context "backup restore failed" do
            it "should raise an exception" do
              new_resource.name('test_backup')
              new_resource.lineage('some_lineage')
              provider.should_receive(:find_latest_backup).and_return(backup_stub)
              provider.stub(:get_current_devices).and_return(['device_1', 'device_2'])
              provider.should_receive(:restore_backup).and_return('failed')
              expect { run_action(:restore) }.to raise_error(RuntimeError)
            end
          end
        end

        context "no backups found in the lineage" do
          it "should raise an exception" do
            new_resource.lineage('some_lineage')
            provider.stub(:find_latest_backup).and_return(nil)
            expect { run_action(:restore) }.to raise_error(RuntimeError)
          end
        end
      end
    end

    describe "#action_cleanup" do
      context "given a backup lineage" do
        it "should clean up snapshots" do
          new_resource.lineage('some_lineage')
          provider.should_receive(:cleanup_backups)
          run_action(:cleanup)
        end
      end
    end
  end

  # Spec test for the helper methods in the provider
  describe "class methods" do
    before(:each) do
      provider.new_resource = new_resource
      provider.load_current_resource
    end

    describe "#cleanup_backups" do
      context "given the backup lineage" do
        it "should cleanup the backups" do
          rotation_options = {
            :keep_last => 1,
            :dailies => 1,
            :weeklies => 1,
            :monthlies => 1,
            :yearlies => 1
          }
          client_stub.should_receive(:backups).and_return(backup_resource)
          provider.should_receive(:get_cloud_href).and_return('some_cloud_href')
          backup_resource.should_receive(:cleanup).with({
            :cloud_href => 'some_cloud_href',
            :lineage => 'some_lineage',
          }.merge(rotation_options))
          provider.send(:cleanup_backups, 'some_lineage', rotation_options)
        end
      end
    end

    describe "#get_volume_type_href" do

      # Creates a dummy volume type.
      #
      # @param name [String] name of the volume type
      # @param id [String] resource UID of the volume type
      # @param size [String] size of the volume type
      # @param href [String] href of the volume type
      #
      def create_test_volume_type(name, href)
        volume_type = double('volume_types')
        volume_type.stub(:name => name, :href => href)
        volume_type
      end

      context "when the cloud is not rackspace-ng" do
        it "should return nil" do
          node.set['cloud']['provider'] = 'some_cloud'
          volume_type = provider.send(:get_volume_type_href, 'some_type')
          volume_type.should be_nil
        end
      end

      context "when the cloud is rackspace-ng" do
        before(:each) do
          sata = create_test_volume_type('sata', 'sata_href')
          ssd = create_test_volume_type('ssd', 'ssd_href')
          volume_type_stub.stub(:index => [sata, ssd])
          client_stub.stub(:volume_types).and_return(volume_type_stub)
        end

        it "should return href of the requested volume type" do
          node.set['cloud']['provider'] = 'rackspace-ng'
          volume_type = provider.send(:get_volume_type_href, 'SATA')
          volume_type.should == 'sata_href'

          volume_type = provider.send(:get_volume_type_href, 'SSD')
          volume_type.should == 'ssd_href'
        end
      end
    end

    describe "#create_backup" do
      it "should create the backup in the cloud" do
        node.set['cloud']['provider'] = 'some_cloud'
        new_resource.lineage('some_lineage')
        new_resource.name('some_name')
        new_resource.description('some description')
        new_resource.from_master(true)

        client_stub.should_receive(:backups).and_return(backup_resource)
        backup_resource.should_receive(:create).with({
          :backup => {
            :lineage => 'some_lineage',
            :name => 'some_name',
            :volume_attachment_hrefs => ['attachment_1', 'attachment_2'],
            :description => 'some description',
            :from_master => true
          }
        }).and_return(backup_resource)
        provider.send(:create_backup, ['attachment_1', 'attachment_2'])
      end
    end

    describe "#find_latest_backup" do
      it "should find latest backup with the given filter" do
        client_stub.should_receive(:backups).and_return(backup_resource)
        timestamp = Time.now
        filter = [
          "latest_before==#{timestamp.utc.strftime('%Y/%m/%d %H:%M:%S %z')}",
          "committed==true",
          "completed==true",
          "from_master==true"
        ]
        backup_resource.should_receive(:index).with({
          :lineage => 'some_lineage',
          :filter => filter
        }).and_return([backup_resource])
        provider.send(:find_latest_backup, 'some_lineage', timestamp, true)
      end
    end

    describe "#get_volume_attachment_hrefs" do
      it "should return the attached volumes based on the given filter" do
        client_stub.should_receive(:volume_attachments).and_return(volume_attachment_resource)
        volume_attachment_resource.should_receive(:index).and_return([volume_attachment_stub])
        attachment_hrefs = provider.send(:get_volume_attachment_hrefs)
        attachment_hrefs.should be_a_kind_of(Array)
      end

      it "should skip the boot disk attached to the instance" do
        client_stub.should_receive(:volume_attachments).and_return(volume_attachment_resource)
        volume_attachment_resource.should_receive(:index).and_return([boot_volume_attachment_stub])
        attachment_hrefs = provider.send(:get_volume_attachment_hrefs)
        attachment_hrefs.should be_a_kind_of(Array)
        attachment_hrefs.should be_empty
      end
    end

    describe "#get_cloud_href" do
      it "should get the href of the cloud" do
        client_stub.should_receive(:get_instance).and_return(instance_stub)
        cloud_href = provider.send(:get_cloud_href)
        cloud_href.should == 'some_cloud_href'
      end
    end

    describe "#get_instance_href" do
      it "should return the instance href" do
        client_stub.should_receive(:get_instance).and_return(instance_stub)
        instance_href = provider.send(:get_instance_href)
        instance_href.should == 'some_href'
      end
    end

    describe "#restore_backup" do
      it "should restore backup" do
        new_resource.name('test_backup')
        new_resource.description('some description')
        provider.stub(:get_instance_href).and_return('some_href')
        provider.stub(:get_volume_type_href).and_return('volume_type_href')
        backup_stub.should_receive(:restore).with({
          :instance_href => 'some_href',
          :backup => {
            :name => 'test_backup',
            :description => 'some description',
            :volume_type_href => 'volume_type_href'
          }
        }).and_return(task_resource)
        status = provider.send(:restore_backup, backup_stub, {:volume_type => 'some_type'})
        status.should == 'completed'
      end
    end

    describe "#get_current_devices" do
      let(:devices) do
        proc_partitions = [
          'major minor  #blocks  name',
          '',
          '1        0  123456789 xvda',
          '1        1     123456 xvda1',
          '2        0    1234567 dm-0',
          '3        0    1234567 dm-1'
        ]
        IO.stub(:readlines).and_return(proc_partitions)
        provider.send(:get_current_devices)
      end

      it "should return at least one partition" do
        devices.should have_at_least(1).items
      end

      it "should not list LVM partitions" do
        devices.select { |item| item =~ /dm-\d/ }.should be_empty
      end

      it "should return items with '/dev' string prefix" do
        devices.reject { |item| item =~ /^\/dev/ }.should be_empty
      end
    end
  end
end
