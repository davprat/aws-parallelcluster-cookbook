# frozen_string_literal: true

#
# Cookbook:: aws-parallelcluster-slurm
# Recipe:: finalize_head_node
#
# Copyright:: 2013-2021 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

execute "check if clustermgtd heartbeat is available" do
  command "cat #{node['cluster']['slurm']['install_dir']}/etc/pcluster/.slurm_plugin/clustermgtd_heartbeat"
  retries 30
  retry_delay 10
end

ruby_block "wait for static fleet capacity" do
  block do
    require 'chef/mixin/shell_out'
    require 'shellwords'
    require 'time'

    up_states = %w[idle alloc mix]
    ice_codes = %w[InsufficientInstanceCapacity InsufficientHostCapacity InsufficientReservedInstanceCapacity MaxSpotInstanceCountExceeded Unsupported SpotMaxPriceTooLow]

    # Example output for sinfo
    # $ /opt/slurm/bin/sinfo -N -h -o '%N %t'
    # ondemand-dy-c5.2xlarge-1 idle~
    # ondemand-dy-c5.2xlarge-2 idle~
    # spot-dy-c5.xlarge-1 idle~
    # spot-st-t2.large-1 down
    # spot-st-t2.large-2 idle
    #
    # /opt/slurm/bin/sinfo -N -h -o '%N %t %H %E'
    # compute-st-cit-1 down~ 2023-01-13T19:35:43 inactive partition
    is_fleet_ready_command = Shellwords.escape(
      "set -o pipefail && #{node['cluster']['slurm']['install_dir']}/bin/sinfo -N -h -o '%N %t %H %E' | { grep -E '^[a-z0-9\\-]+\\-st\\-[a-z0-9\\-]+\\-[0-9]+ .*' || true; }"
    )

    fleet_ready = lambda do
      status = shell_out!("/bin/bash -c #{is_fleet_ready_command}").stdout.strip
      Chef::Log.info("Static fleet status:\n#{status}")

      down_nodes = []
      ice_nodes = []

      # Split down nodes into sets of those that are down
      # due to ICE and those that are down for any other
      # reason.
      status.each_line(chomp: true) do |line|
        fields = line.split(" ", 4)
        begin
          match_data = /^\(Code:(.*)\).*/.match(fields[3])
          if match_data and ice_codes.include? match_data[1]
            Chef::Log.info("Adding node with code #{match_data} to ICE nodes")
            ice_nodes << fields
          else
            down_nodes << fields
          end
        end unless up_states.include? fields[1]
      end

      # If there are no down or ICE nodes, then we are done waiting.
      return true if down_nodes.empty? and ice_nodes.empty?

      # Return false if the only down nodes are down due to ICE.
      return false if down_nodes.empty?

      # If we have nodes down for reasons other than ICE,
      # we need to check if we've been waiting on them to
      # come up for too long.
      ahora = Time.now
      down_nodes.each do |node_status|
        down_time = Time.parse("#{node_status[2]}+0000" )
        delta = ahora - down_time
        Chef::Log.info("Node #{node_status[0]} has been down for #{delta} seconds with status #{node_status[3]}")

        # Raise an error if we've been waiting too long for one or
        # more nodes to come up.
        raise "Timed out waiting for static compute fleet to start" if delta > node['cluster']['slurm_static_fleet_timeout']
      end

      # If we haven't timed out, then keep waiting for the
      # nodes to come up.
      return false
    end

    until fleet_ready.()
      Chef::Log.info("Waiting for static fleet capacity provisioning")
      sleep(15)
    end
    Chef::Log.info("Static fleet capacity is ready")
  end
end
