# rightscale_backup cookbook

[![Build Status](https://travis-ci.org/rightscale-cookbooks/rightscale_backup.png?branch=master)](https://travis-ci.org/rightscale-cookbooks/rightscale_backup)

This cookbook provides a `rightscale_backup` resource that can create,
restore, and clean up block device storage ("volume") backups on numerous
public and private IaaS clouds.

A backup represents a collection of volume snapshots taken at the same
time from one or more volumes attached to the server. A backup belongs
to a series of backups, called the "lineage". Maintaining a lineage allows for
point-in-time data recovery using timestamps (even if the snapshots are taken from
different volumes). It also supports a more sophisticated algorithm for backup
rotation/retention, as opposed to simple snapshot truncation.

The `rightscale_backup` resource uses RightScale's instance-facing API to
manage backups in the cloud.

# Requirements

* The system being configured must be a RightScale managed VM to have the
required access to the RightScale API.
* Chef 11 or higher.
* Requires a RightScale account that is registered with all the cloud vendors
you expect to provision on (e.g. AWS, Rackspace, Openstack, CloudStack, GCE,
and Azure).

# Recipes

## default

The default recipe installs the [right_api_client gem][RightAPI Client] to make
instance-facing RightScale API calls.

# Resource/Providers

## rightscale_backup

A resource to create, restore, and cleanup backups in the cloud.

### Action: create

Creates a snapshot for every volume attached to the server. The newly created snapshot
will be tagged with the following

<table>
  <tr>
    <th>Tag Name</th>
    <th>Description</th>
  </tr>
  <tr>
    <td><tt>rs_backup:lineage=&lt;string&gt;</tt></td>
    <td>Lineage name of the backup</td>
  </tr>
  <tr>
    <td><tt>rs_backup:backup_id=&lt;UUID&gt;</tt></td>
    <td>Unique identifier for a backup (all snapshots in a backup will share this ID)</td>
  </tr>
  <tr>
    <td><tt>rs_backup:committed=true</tt></td>
    <td>The backup is committed</td>
  </tr>
  <tr>
    <td><tt>rs_backup:count=X</tt></td>
    <td>Number of snapshots in the backup</td>
  </tr>
  <tr>
    <td><tt>rs_backup:device=&lt;device&gt;</tt></td>
    <td>Device to which the volume was attached</td>
  </tr>
  <tr>
    <td><tt>rs_backup:position=Y</tt></td>
    <td>Position of the snapshot in a backup</td>
  </tr>
  <tr>
    <td><tt>rs_backup:timestamp=&lt;timestamp&gt;</tt></td>
    <td>Time at which the backup was taken</td>
  </tr>
</table>

A backup is considered a *perfect backup* when it is completed (all the snapshots are
completed), committed (all the snapshots are committed), and the number of snapshots
it found is equal to the number in the "rs_backup:count=" tag on each of the snapshots.

#### Attributes
<table>
  <tr>
    <th>Name</th>
    <th>Description</th>
    <th>Default</th>
    <th>Required</th>
  </tr>
  <tr>
    <td>nickname</td>
    <td>Name of the backup to be created. All snapshots in the backup will be created
with this name.</td>
    <td></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>lineage</td>
    <td>Lineage in which the backup must belong</td>
    <td></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>description</td>
    <td>Description for the backup</td>
    <td></td>
    <td>No</td>
  </tr>
  <tr>
    <td>from_master</td>
    <td>Set this to 'true' to create a <tt>rs_backup:from_master=true</tt> true on the
snapshots which can be used in filtering</td>
    <td><tt>false</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>timeout</td>
    <td>Throws an error if the volume could not be backed up in the cloud within this
timeout (in minutes)</td>
    <td><tt>15</tt></td>
    <td>No</td>
  </tr>
</table>

### Action: restore

Restores a backup from the cloud. This will

* create a volume for each snapshot in the backup
* attach all the created volumes to the server at the device specified in the snapshot
(obtained from `rs_backup:device=`). NOTE: If the devices are already being used on the
server, the restore will fail.

#### Attributes
<table>
  <tr>
    <th>Name</th>
    <th>Description</th>
    <th>Default</th>
    <th>Required</th>
  </tr>
  <tr>
    <td>nickname</td>
    <td>Name of the backup to be restored</td>
    <td></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>lineage</td>
    <td>Lineage in which the backup belongs</td>
    <td></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>description</td>
    <td>Description to be set for the volumes created from the snapshots in the
backup. If description is not given, the description in the snapshots will be used
for the newly created volumes.</td>
    <td></td>
    <td>No</td>
  </tr>
  <tr>
    <td>timestamp</td>
    <td>The timestamp on the backup. The latest <em>perfect backup</em> on or before
this timestamp in the specified lineage will be picked for restore. This attribute
can be set using the Time class or the seconds since UNIX epoch (Integer)</td>
    <td></td>
    <td>No</td>
  </tr>
  <tr>
    <td>size</td>
    <td>All volumes created from the snapshot will be of this size. NOTE: This size
must be equal to or larger than the size of the snapshots in the backup.
WARNING: Some clouds do not support volume resizing and throws an exception when we
pass this parameter. On clouds that supports resizing (currently only tested in EC2),
the volumes will be created with this size instead of the original backup's size.</td>
    <td></td>
    <td>No</td>
  </tr>
  <tr>
    <td>timeout</td>
    <td>Throws an error if the volume could not be restored within this timeout (in minutes)</td>
    <td><tt>15</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>options</td>
    <td>Optional parameters hash. For example, <tt>:volume_type</tt> on Rackspace Open Clouds
can be specified to restore the volume as an 'SATA' or 'SSD' device.</td>
    <td></td>
    <td>No</td>
  </tr>
</table>

### Action: cleanup

Deletes old backups from the cloud. For all the *perfect backups*, the constraints of
keep_last, dailies, weeklies, monthlies, and yearlies attributes will be applied
(See 'Parameters' section below). The algorithm for choosing the backups to keep is
enforced by the RightScale API which is the union of those set of backups if each of
those conditions are applied independently.

```
backups_to_keep = backups_to_keep(keep_last) U backups_to_keep(dailies) U
backups_to_keep(weeklies) U backups_to_keep(monthlies) U backups_to_keep(yearlies)
```

An *imperfect backup* is picked up for clean up only if there exists a perfect backup
with a newer timestamp. No constraints will be applied on *imperfect backups* and all
of them will be cleaned up.

#### Attributes
<table>
  <tr>
    <th>Name</th>
    <th>Description</th>
    <th>Default</th>
    <th>Required</th>
  </tr>
  <tr>
    <td>lineage</td>
    <td>Lineage in which the backups belong</td>
    <td></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>keep_last</td>
    <td>Number of backups to keep from deleting</td>
    <td><tt>60</tt></td>
    <td>Yes</td>
  </tr>
  <tr>
    <td>dailies</td>
    <td>Number of daily backups to keep</td>
    <td><tt>1</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>monthlies</td>
    <td>Number of monthly backups to keep</td>
    <td><tt>12</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>weeklies</td>
    <td>Number of weekly backups to keep</td>
    <td><tt>4</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>yearlies</td>
    <td>Number of yearly backups to keep</td>
    <td><tt>2</tt></td>
    <td>No</td>
  </tr>
  <tr>
    <td>timeout</td>
    <td>Throws an error if the volume could not be cleaned up in the cloud within this
timeout (in minutes)</td>
    <td><tt>15</tt></td>
    <td>No</td>
  </tr>
</table>

# Usage

This resource only handles manipulating volume backups. Managing volumes is
handled by the [rightscale_volume][RightScale Volume] resource.

**Example 1:** Creates and attaches 2 volumes using the [rightscale_volume][RightScale Volume] resource,
and then takes a backup of the volumes using the `rightscale_backup` resource.

```ruby
# Creates and attaches two 1 GB volumes
2.times do |count|
  rightscale_volume "db_data_volume_#{count}" do
    size 1
    action [:create, :attach]
  end
end

# Backs up the two volumes to a 'db_backup_lineage' lineage
rightscale_backup "db_data_volume_backup" do
  lineage 'db_backup_lineage'
  action :create
end
```

**Example 2:** Restores the backup (created in Example 1) to the server

```ruby
# Restores the latest backup in the 'db_backup_lineage' taken on or before
# the UNIX timestamp '1391118125'
rightscale_backup "db_data_volume_backup" do
  lineage 'db_backup_lineage'
  timestamp 1391118125
  action :restore
end
```

**Example 3:** Deletes old backups

```ruby
# Deletes old backups from the 'db_backup_lineage' lineage. After this action
# there will be only 2 backups in the cloud.
rightscale_backup "db_data_volume_backup" do
  lineage 'db_backup_lineage'
  keep_last 2
  monthlies 1
  yearlies 1
  dailies 1
  weeklies 1
  action :cleanup
end
```

[RightAPI Client]: https://rubygems.org/gems/right_api_client
[RightScale Volume]: http://community.opscode.com/cookbooks/rightscale_volume

# Author

Author:: RightScale, Inc. (<cookbooks@rightscale.com>)
