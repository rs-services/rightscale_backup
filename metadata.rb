name             'rightscale_backup'
maintainer       'RightScale, Inc.'
maintainer_email 'cookbooks@rightscale.com'
license          'Apache 2.0'
description      'Provides a resource to manage volume backups on any cloud RightScale supports.'
long_description IO.read(File.join(File.dirname(__FILE__), 'README.md'))
version          '1.1.0'

depends 'rightscale_volume', '~> 1.1.0'

recipe "rightscale_backup::default", "Default recipe for installing required packages/gems."
