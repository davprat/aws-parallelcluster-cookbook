require 'spec_helper'

class Efs
  def self.install_utils(chef_run)
    chef_run.converge_dsl do
      efs 'install_utils' do
        action :install_utils
      end
    end
  end
end

def mock_get_package_version(package, expected_version)
  stubs_for_resource('efs') do |res|
    allow(res).to receive(:get_package_version).with(package).and_return(expected_version)
  end
end

def mock_already_installed(package, expected_version, installed)
  stubs_for_resource('efs') do |res|
    allow(res).to receive(:already_installed?).with(package, expected_version).and_return(installed)
  end
end

describe 'efs:install_utils' do
  context "on amazon2" do
    let(:chef_run) do
      ChefSpec::Runner.new(
        platform: 'amazon', version: '2',
        step_into: ['efs']
      ) do |node|
        node.override['cluster']['efs_utils']['version'] = '1.2.3'
      end
    end
    let(:node) { chef_run.node }

    context "when same version of amazon-efs-utils already installed" do
      before do
        mock_get_package_version('amazon-efs-utils', '1.2.3')
        Efs.install_utils(chef_run)
      end

      it 'does not install amazon-efs-utils' do
        is_expected.not_to install_package('amazon-efs-utils')
      end
    end

    context "when newer version of amazon-efs-utils already installed" do
      before do
        mock_get_package_version('amazon-efs-utils', '1.3.2')
        Efs.install_utils(chef_run)
      end

      it 'does not install amazon-efs-utils' do
        is_expected.not_to install_package('amazon-efs-utils')
      end
    end

    context "when amazon-efs-utils not installed" do
      before do
        mock_get_package_version('amazon-efs-utils', '')
        Efs.install_utils(chef_run)
      end

      it 'installs amazon-efs-utils' do
        is_expected.to install_package('amazon-efs-utils').with(retries: 3).with(retry_delay: 5)
      end
    end

    context "when older version of amazon-efs-utils installed" do
      before do
        mock_get_package_version('amazon-efs-utils', '1.1.4')
        Efs.install_utils(chef_run)
      end

      it 'installs amazon-efs-utils' do
        is_expected.to install_package('amazon-efs-utils').with(retries: 3).with(retry_delay: 5)
      end
    end
  end

  for_oses([
             %w(ubuntu 18.04),
             %w(ubuntu 20.04),
           ]) do |platform, version|
    context "on #{platform}#{version}" do
      let(:chef_run) do
        ChefSpec::Runner.new(
          platform: platform, version: version,
          step_into: ['efs']
        )
      end
      let(:node) { chef_run.node }
      let(:tarball_path) { 'TARBALL PATH' }
      let(:tarball_url) { 'https://TARBALL/URL' }
      let(:tarball_checksum) { 'TARBALL CHECKSUM' }
      let(:source_dir) { 'SOURCE DIR' }
      let(:utils_version) { '1.2.3' }
      let(:bash_code) do
        <<-EFSUTILSINSTALL
      set -e
      tar xf #{tarball_path}
      cd efs-utils-#{utils_version}
      ./build-deb.sh
      apt-get -y install ./build/amazon-efs-utils*deb
      EFSUTILSINSTALL
      end

      before do
        node.override['cluster']['efs_utils']['tarball_path'] = tarball_path
        node.override['cluster']['efs_utils']['url'] = tarball_url
        node.override['cluster']['efs_utils']['sha256'] = tarball_checksum
        node.override['cluster']['efs_utils']['version'] = utils_version
        node.override['cluster']['sources_dir'] = source_dir
      end

      context "utils package not yet installed" do
        before do
          mock_already_installed('amazon-efs-utils', utils_version, false)
          Efs.install_utils(chef_run)
        end

        it 'downloads tarball' do
          is_expected.to create_if_missing_remote_file(tarball_path)
            .with(source: tarball_url)
            .with(mode: '0644')
            .with(retries: 3)
            .with(retry_delay: 5)
            .with(checksum: tarball_checksum)
        end

        it 'installs package from downloaded tarball' do
          is_expected.to run_bash('install efs utils')
            .with(cwd: source_dir)
            .with(code: bash_code)
        end
      end

      context "utils package already installed" do
        before do
          mock_already_installed('amazon-efs-utils', utils_version, true)
          Efs.install_utils(chef_run)
        end

        it 'does not download tarball' do
          is_expected.not_to create_if_missing_remote_file(tarball_path)
        end

        it 'does not install package from downloaded tarball' do
          is_expected.not_to run_bash('install efs utils')
        end
      end
    end
  end

  for_oses([
    %w(centos 7),
    %w(redhat 8),
  ]) do |platform, version|
    context "on #{platform}#{version}" do
      let(:chef_run) do
        ChefSpec::Runner.new(
          platform: platform, version: version,
          step_into: ['efs']
        )
      end
      let(:node) { chef_run.node }
      let(:tarball_path) { 'TARBALL PATH' }
      let(:tarball_url) { 'https://TARBALL/URL' }
      let(:tarball_checksum) { 'TARBALL CHECKSUM' }
      let(:source_dir) { 'SOURCE DIR' }
      let(:utils_version) { '1.2.3' }
      let(:bash_code) do
        <<-EFSUTILSINSTALL
      set -e
      tar xf #{tarball_path}
      cd efs-utils-#{utils_version}
      make rpm
      yum -y install ./build/amazon-efs-utils*rpm
        EFSUTILSINSTALL
      end
      let(:required_packages) do
        {
          "centos" => 'rpm-build',
          "redhat" => %w(rpm-build make),
        }
      end

      before do
        node.override['cluster']['efs_utils']['tarball_path'] = tarball_path
        node.override['cluster']['efs_utils']['url'] = tarball_url
        node.override['cluster']['efs_utils']['sha256'] = tarball_checksum
        node.override['cluster']['efs_utils']['version'] = utils_version
        node.override['cluster']['sources_dir'] = source_dir
      end

      context "utils package not yet installed" do
        before do
          mock_already_installed('amazon-efs-utils', utils_version, false)
          Efs.install_utils(chef_run)
        end

        it 'installs prerequisites' do
          is_expected.to install_package(required_packages[platform])
            .with(retries: 3)
            .with(retry_delay: 5)
        end

        it 'downloads tarball' do
          is_expected.to create_if_missing_remote_file(tarball_path)
            .with(source: tarball_url)
            .with(mode: '0644')
            .with(retries: 3)
            .with(retry_delay: 5)
            .with(checksum: tarball_checksum)
        end

        it 'installs package from downloaded tarball' do
          is_expected.to run_bash('install efs utils')
            .with(cwd: source_dir)
            .with(code: bash_code)
        end
      end

      context "utils package already installed" do
        before do
          mock_already_installed('amazon-efs-utils', utils_version, true)
          Efs.install_utils(chef_run)
        end

        it 'does not download tarball' do
          is_expected.not_to create_if_missing_remote_file(tarball_path)
        end

        it 'does not install package from downloaded tarball' do
          is_expected.not_to run_bash('install efs utils')
        end
      end
    end
  end
end