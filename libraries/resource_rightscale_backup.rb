#
# Cookbook Name:: rightscale_backup
# Library:: resource_rightscale_backup
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

require 'chef/resource'

class Chef
  class Resource
    class RightscaleBackup < Chef::Resource
      def initialize(name, run_context = nil)
        super
        @resource_name = :rightscale_backup
        @action = :create
        @allowed_actions.push(:create, :restore, :cleanup)
        @provider = Chef::Provider::RightscaleBackup
      end

      def name(arg = nil)
        set_or_return(
          :name,
          arg,
          :kind_of => String
        )
      end

      def description(arg = nil)
        set_or_return(
          :description,
          arg,
          :kind_of => String
        )
      end

      def lineage(arg = nil)
        set_or_return(
          :lineage,
          arg,
          :kind_of => String
        )
      end

      def devices(arg = nil)
        set_or_return(
          :devices,
          arg,
          :kind_of => Array,
          :default => []
        )
      end

      def from_master(arg = nil)
        set_or_return(
          :from_master,
          arg,
          :equal_to => [true, false],
          :default => false
        )
      end

      def size(arg = nil)
        set_or_return(
          :size,
          arg,
          :default => 1,
          :kind_of => Integer
        )
      end

      def timeout(arg = nil)
        set_or_return(
          :timeout,
          arg,
          :default => 15,
          :kind_of => Integer
        )
      end

      def keep_last(arg = nil)
        set_or_return(
          :keep_last,
          arg,
          :default => 60,
          :kind_of => Integer
        )
      end

      def dailies(arg = nil)
        set_or_return(
          :dailies,
          arg,
          :default => 1,
          :kind_of => Integer
        )
      end

      def monthlies(arg = nil)
        set_or_return(
          :monthlies,
          arg,
          :default => 12,
          :kind_of => Integer
        )
      end

      def weeklies(arg = nil)
        set_or_return(
          :weeklies,
          arg,
          :default => 4,
          :kind_of => Integer
        )
      end

      def yearlies(arg = nil)
        set_or_return(
          :yearlies,
          arg,
          :default => 2,
          :kind_of => Integer
        )
      end

      # Hash that holds cloud provider specific attributes such as IOPS or
      # volume_type ('SATA'/'SSD').
      #
      # @param arg [Hash] the optional parameters for actions
      #
      # @return [Hash] the optional parameters
      #
      def options(arg = nil)
        set_or_return(
          :options,
          arg,
          :kind_of => Hash,
          :default => {}
        )
      end
    end
  end
end
