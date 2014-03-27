# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 Novell, Inc. All Rights Reserved.
#
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#
#

require "yast"

require "tmpdir"
require "fileutils"

require "registration/exceptions"

module Registration
  Yast.import "Mode"
  Yast.import "Pkg"
  Yast.import "Installation"
  Yast.import "PackageCallbacksInit"

  class SwMgmt
    include Yast
    include Yast::Logger
    extend Yast::I18n

    textdomain "registration"

    ZYPP_DIR = "/etc/zypp"

    def self.init
      # display progress when refreshing repositories
      PackageCallbacksInit.InitPackageCallbacks
      Pkg.TargetInitialize(Installation.destdir)
      Pkg.TargetLoad
    end

    # during installation /etc/zypp directory is not writable (mounted on
    # a read-only file system), the workaround is to copy the whole directory
    # structure into a writable temporary directory and override the original
    # location by "mount -o bind"
    def self.zypp_config_writable!
      return if !Mode.installation || !Mode.update || File.writable?(ZYPP_DIR)

      log.info "Copying libzypp config to a writable place"

      # create writable zypp directory structure in /tmp
      tmpdir = Dir.mktmpdir

      log.info "Copying #{ZYPP_DIR} to #{tmpdir} ..."
      ::FileUtils.cp_r ZYPP_DIR, tmpdir

      log.info "Mounting #{tmpdir} to #{ZYPP_DIR}"
      `mount -o bind #{tmpdir}/zypp #{ZYPP_DIR}`
    end

    def self.base_products_to_register
      # just for debugging:
      # return [{"name" => "SLES", "arch" => "x86_64", "version" => "12-1.47"}]

      # during installation the products are :selected,
      # on a running system the products are :installed
      # during upgrade use the newer selected product (same as in installation)
      products = Pkg.ResolvableProperties("", :product, "").find_all do |p|
        if Mode.normal
          # in installed system the base product has valid type
          p["status"] == :installed && p["type"] == "base"
        else
          # however during installation it's not set yet
          # but the base product comes from the first repository
          p["status"] == :selected && p["source"] == 0
        end
      end

      # filter out not needed data
      product_info = products.map do |p|
        { "name" => p["name"], "arch" => p["arch"], "version" => p["version"]}
      end

      log.info("Products to register: #{product_info}")

      product_info
    end

    # add the services to libzypp and load (refresh) them
    def self.add_services(product_services, credentials)
      # save repositories before refreshing added services (otherwise
      # pkg-bindings will treat them as removed by the service refresh and
      # unload them)
      if !Pkg.SourceSaveAll
        # error message
        raise Registration::PkgError, N_("Saving repository configuration failed.")
      end

      # services for registered products
      product_services.map(&:services).flatten.each do |service|
        log.info "Adding service #{service.name.inspect} (#{service.url})"

        credentials_file = Helpers.credentials_from_url(service.url)

        if credentials_file
          # TODO FIXME: SCC currenly does not return credentials for the service,
          # just reuse the global credentials and save to a different file
          credentials.file = credentials_file
          credentials.write
        end

        if !Pkg.ServiceAdd(service.name, service.url.to_s)
          # error message
          raise ::Registration::ServiceError.new(N_("Adding service '%s' failed."), service.name)
        end
        # refresh works only for saved services
        if !Pkg.ServiceSave(service.name)
          # error message
          raise ::Registration::ServiceError.new(N_("Saving service '%s' failed."), service.name)
        end

        if !Pkg.ServiceRefresh(service.name)
          # error message
          raise ::Registration::ServiceError.new(N_("Refreshing service '%s' failed."), service.name)
        end
      end
    ensure
      Pkg.SourceSaveAll
    end

    # get list of repositories belonging to registered services
    def self.service_repos(product_services)
      repo_data = Pkg.SourceGetCurrent(false).map do |repo|
        data = Pkg.SourceGeneralData(repo)
        data["SrcId"] = repo
        data
      end

      service_names = product_services.map(&:services).flatten.map(&:name)
      log.info "Added services: #{service_names.inspect}"

      # select only repositories belonging to the product services
      repos = repo_data.select{|repo| service_names.include?(repo["service"])}
      log.info "Service repositories: #{repos}"

      repos
    end

    # copy old NCC/SCC credentials from the old installation to new SCC credentials
    def self.copy_old_credentials(target_dir)
      # check for NCC credentials
      dir = SccApi::Credentials::DEFAULT_CREDENTIALS_DIR
      ncc_file = File.join(target_dir, dir, "NCCcredentials")
      scc_file = File.join(target_dir, dir, "SCCCredentials")
      new_file = File.join(dir, "SCCCredentials")

      if File.exist?(ncc_file)
        log.info "Copying the old NCC credentials from previous installation"
        log.debug "Copying #{ncc_file} to #{new_file}"
        File.cp(ncc_file, new_file)
      end

      if File.exist?(scc_file)
        log.info "Copying the old SCC credentials from previous installation"
        log.debug "Copying #{scc_file} to #{new_file}"
        File.cp(scc_file, new_file)
      end
    end

  end
end

