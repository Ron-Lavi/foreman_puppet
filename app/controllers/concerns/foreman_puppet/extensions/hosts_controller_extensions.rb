module ForemanPuppet
  module Extensions
    module HostsControllerExtensions
      extend ActiveSupport::Concern

      PUPPETMASTER_ACTIONS = %i[externalNodes lookup].freeze
      PUPPET_AJAX_REQUESTS = %w[hostgroup_or_environment_selected puppetclass_parameters].freeze

      MULTIPLE_EDIT_ACTIONS = %w[select_multiple_environment update_multiple_environment
                                 select_multiple_puppet_proxy update_multiple_puppet_proxy
                                 select_multiple_puppet_ca_proxy update_multiple_puppet_ca_proxy].freeze

      included do
        add_smart_proxy_filters PUPPETMASTER_ACTIONS, features: ['Puppet']
        alias_method :ajax_request_for_puppet_host_extensions, :ajax_request

        before_action :ajax_request_for_puppet_host_extensions, only: PUPPET_AJAX_REQUESTS
        before_action :taxonomy_scope_for_puppet_host_extensions, only: PUPPET_AJAX_REQUESTS
        before_action :find_multiple_for_puppet_host_extensions, only: MULTIPLE_EDIT_ACTIONS
        before_action :validate_multiple_puppet_proxy, only: :update_multiple_puppet_proxy
        before_action :validate_multiple_puppet_ca_proxy, only: :update_multiple_puppet_ca_proxy

        define_action_permission %w[externalNodes], :view
        define_action_permission MULTIPLE_EDIT_ACTIONS, :edit

        set_callback :set_class_variables, :after, :set_puppet_class_variables

        helper ForemanPuppet::HostsHelper
        helper ForemanPuppet::HostsAndHostgroupsHelper
        helper ForemanPuppet::PuppetclassesHelper
        helper ForemanPuppet::PuppetclassLookupKeysHelper
      end

      # TODO: unless ForemanPuppet.extracted_from_core?
      def select_multiple_puppet_proxy_hosts_path(*args)
        foreman_puppet.select_multiple_puppet_proxy_hosts_path(*args)
      end

      def hostgroup_or_environment_selected
        refresh_host
        set_class_variables(@host)
        ::Taxonomy.as_taxonomy @organization, @location do
          if @environment || @hostgroup
            render partial: 'hosts/form_puppet_enc_tab', locals: { subject: @host, resource_type: :host }
          else
            logger.info 'environment_id or hostgroup_id is required to render puppetclasses'
          end
        end
      end

      def puppetclass_parameters
        ::Taxonomy.as_taxonomy @organization, @location do
          render partial: 'foreman_puppet/puppetclasses/classes_parameters', locals: { obj: refresh_host }
        end
      end

      def select_multiple_environment
      end

      def update_multiple_environment
        # simple validations
        if params[:environment].nil? || (id = params['environment']['id']).nil?
          error _('No environment selected!')
          redirect_to(foreman_puppet.select_multiple_environment_hosts_path)
          return
        end

        ev = ForemanPuppet::Environment.find_by(id: id)

        # update the hosts
        @hosts.each do |host|
          puppet = host.puppet || host.build_puppet
          puppet.environment = id == 'inherit' && host.hostgroup.present? ? host.hostgroup.puppet&.environment : ev
          host.save(validate: false)
        end

        success _('Updated hosts: changed environment')
        redirect_back_or_to hosts_path
      end

      # returns a yaml file ready to use for puppet external nodes script
      # expected a fqdn parameter to provide hostname to lookup
      # see example script in extras directory
      # will return HTML error codes upon failure
      # rubocop:disable Naming/MethodName
      def externalNodes
        certname = params[:name].to_s
        @host ||= resource_base.find_by certname: certname
        @host ||= resource_base.friendly.find certname
        unless @host
          not_found
          return
        end

        begin
          respond_to do |format|
            # don't break lines in yaml to support Ruby < 1.9.3
            # Remove the HashesWithIndifferentAccess using 'deep_stringify_keys',
            # then we turn it into YAML
            host_info_yaml = @host.info.deep_stringify_keys.to_yaml(line_width: -1)
            format.html { render html: ActionController::Base.helpers.tag.pre(ERB::Util.html_escape(host_info_yaml)) }
            format.yml { render plain: host_info_yaml }
          end
        rescue StandardError => e
          Foreman::Logging.exception("Failed to generate external nodes for #{@host}", e)
          render plain: _('Unable to generate output, Check log files'),
            status: :precondition_failed
        end
      end
      # rubocop:enable Naming/MethodName

      # TODO: seems to be useless
      def environment_from_param
        # simple validations
        if params[:environment].nil? || (id = params['environment']['id']).nil?
          error _('No environment selected!')
          redirect_to(foreman_puppet.select_multiple_environment_hosts_path)
          return
        end

        id
      end

      def get_environment_id(env_params)
        env_params['id'] if env_params
      end

      def get_environment_for(host, id)
        if id == 'inherit' && host.hostgroup.present?
          host.hostgroup.environment
        else
          ForemanPuppet::Environment.find_by(id: id)
        end
      end

      def validate_multiple_puppet_proxy
        validate_multiple_proxy(foreman_puppet.select_multiple_puppet_proxy_hosts_path)
      end

      def validate_multiple_puppet_ca_proxy
        validate_multiple_proxy(select_multiple_puppet_ca_proxy_hosts_path)
      end

      def validate_multiple_proxy(redirect_path)
        if params[:proxy].nil? || (proxy_id = params[:proxy][:proxy_id]).nil?
          error _('No proxy selected!')
          redirect_to(redirect_path)
          return false
        end

        if proxy_id.present? && !::SmartProxy.find_by(id: proxy_id)
          error _('Invalid proxy selected!')
          redirect_to(redirect_path)
          false
        end
      end

      def update_multiple_proxy(proxy_type, host_update_method)
        proxy_id = params[:proxy][:proxy_id]
        proxy = (SmartProxy.find_by(id: proxy_id) if proxy_id)

        failed_hosts = {}

        @hosts.each do |host|
          host.send(host_update_method, proxy)
          host.save!
        rescue StandardError => e
          failed_hosts[host.name] = e
          message = format(_('Failed to set %{proxy_type} proxy for %{host}.'), host: host, proxy_type: proxy_type)
          Foreman::Logging.exception(message, e)
        end

        if failed_hosts.empty?
          if proxy
            success format(_('The %{proxy_type} proxy of the selected hosts was set to %{proxy_name}'), proxy_name: proxy.name, proxy_type: proxy_type)
          else
            success format(_('The %{proxy_type} proxy of the selected hosts was cleared.'), proxy_type: proxy_type)
          end
        else
          error format(n_('The %{proxy_type} proxy could not be set for host: %{host_names}.',
            'The %{proxy_type} puppet ca proxy could not be set for hosts: %{host_names}',
            failed_hosts.count), proxy_type: proxy_type, host_names: failed_hosts.map { |h, err| "#{h} (#{err})" }.to_sentence)
        end
        redirect_back_or_to hosts_path
      end

      def handle_proxy_messages(errors, proxy, proxy_type)
        if errors.empty?
          if proxy
            success format(_('The %{proxy_type} proxy of the selected hosts was set to %{proxy_name}.'), proxy_name: proxy.name, proxy_type: proxy_type)
          else
            success format(_('The %{proxy_type} proxy of the selected hosts was cleared.'), proxy_type: proxy_type)
          end
        else
          error format(n_('The %{proxy_type} proxy could not be set for host: %{host_names}.',
            'The %{proxy_type} puppet ca proxy could not be set for hosts: %{host_names}',
            errors.count), proxy_type: proxy_type, host_names: errors.map { |h, err| "#{h} (#{err})" }.to_sentence)
        end
      end

      def select_multiple_puppet_proxy
      end

      def update_multiple_puppet_proxy
        update_multiple_proxy(_('Puppet'), :puppet_proxy=)
      end

      def select_multiple_puppet_ca_proxy
      end

      def update_multiple_puppet_ca_proxy
        update_multiple_proxy(_('Puppet CA'), :puppet_ca_proxy=)
      end

      def set_puppet_class_variables
        @environment = @host.puppet&.environment
      end

      def taxonomy_scope_for_puppet_host_extensions
        taxonomy_scope
      end

      def find_multiple_for_puppet_host_extensions
        find_multiple
      end
    end
  end
end
