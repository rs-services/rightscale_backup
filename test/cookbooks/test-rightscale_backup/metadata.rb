name             'test-rightscale_backup'
maintainer       'RightScale, Inc.'
maintainer_email 'cookbooks@rightscale.com'
license          'Apache 2.0'
description      'A wrapper cookbook to test rightscale_backup cookbook'
version          IO.read(File.join(File.dirname(__FILE__), 'VERSION')) rescue '0.1.0'

depends 'rightscale_volume'
depends 'rightscale_backup'

recipe 'test-rightscale_backup::test', 'Test recipe for testing rightscale_backup cookbook'
