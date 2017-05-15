module EmsCommon
  extend ActiveSupport::Concern

  included do
    include Mixins::GenericSessionMixin
    include Mixins::MoreShowActions

    # This is a temporary hack ensuring that @ems will be set.
    # Once we use @record in place of @ems, this can be removed
    # together with init_show_ems
    alias_method :init_show_generic, :init_show
    alias_method :init_show, :init_show_ems

    helper_method :textual_group_list
    private :textual_group_list
  end

  def init_show_ems
    result = init_show_generic
    @ems = @record
    result
  end

  def textual_group_list
    [
      %i(properties status),
      %i(relationships topology smart_management)
    ]
  end

  def show_props
    drop_breadcrumb(:name => @ems.name + _(" (Properties)"), :url => show_link(@ems, :display => "props"))
  end

  def show_ems_folders
    if params[:vat]
      drop_breadcrumb(:name => @ems.name + _(" (VMs & Templates)"),
                      :url  => show_link(@ems, :display => "ems_folder", :vat => "true"))
    else
      drop_breadcrumb(:name => @ems.name + _(" (Hosts & Clusters)"),
                      :url  => show_link(@ems, :display => "ems_folders"))
    end
    @showtype = "config"

    cluster = @record
    @datacenter_tree = TreeBuilderVat.new(:vat_tree, :vat, @sb, true, cluster, !!params[:vat])
    self.x_active_tree = :vat_tree
  end

  def show_ad_hoc_metrics
    @showtype = "ad_hoc_metrics"
    @lastaction = "show_ad_hoc_metrics"
    drop_breadcrumb(:name => @ems.name + _(" (Ad hoc Metrics)"), :url => show_link(@ems))
  end

  def display_block_storage_managers
    nested_list('block_storage_manager', ManageIQ::Providers::StorageManager, :parent_method => :block_storage_managers)
  end

  def display_object_storage_managers
    nested_list('object_storage_manager', ManageIQ::Providers::StorageManager, :parent_method => :object_storage_managers)
  end

  def display_storage_managers
    nested_list('storage_manager', ManageIQ::Providers::StorageManager, :parent_method => :storage_managers)
  end

  def display_ems_clusters
    nested_list('ems_cluster', EmsCluster, :breadcrumb_title => title_for_clusters)
  end

  def display_persistent_volumes
    nested_list('persistent_volume', PersistentVolume, :parent_method => :persistent_volumes)
  end

  def display_hosts
    nested_list('hosts', Host, :breadcrumb_title => _("Managed Hosts"))
  end

  class_methods do
    def display_methods
      %w(
        availability_zones block_storage_managers cloud_networks cloud_object_store_containers cloud_subnets
        cloud_tenants cloud_volumes cloud_volume_snapshots configuration_jobs container_builds container_groups
        container_image_registries container_images container_nodes container_projects container_replicators
        container_routes containers container_services container_templates ems_clusters flavors floating_ips
        host_aggregates hosts images instances load_balancers middleware_datasources middleware_deployments
        middleware_domains middleware_messagings middleware_server_groups middleware_servers miq_templates
        network_ports network_routers object_storage_managers orchestration_stacks persistent_volumes
        security_groups storage_managers storages vms
      )
    end

    def custom_display_modes
      %w(props ems_folders ad_hoc_metrics)
    end

    def default_show_template
      "shared/views/ems_common/show"
    end
  end


  def new
    assert_privileges("#{permission_prefix}_new")
    @ems = model.new
    set_form_vars
    @in_a_form = true
    session[:changed] = nil
    drop_breadcrumb(:name => _("Add New %{table}") % {:table => ui_lookup(:table => @table_name)},
                    :url  => "/#{controller_name}/new")
  end

  def create
    assert_privileges("#{permission_prefix}_new")
    return unless load_edit("ems_edit__new")
    get_form_vars
    case params[:button]
    when "add"
      if @edit[:new][:emstype].blank?
        add_flash(_("Type is required"), :error)
      end

      if @edit[:new][:emstype] == "scvmm" && @edit[:new][:default_security_protocol] == "kerberos" && @edit[:new][:realm].blank?
        add_flash(_("Realm is required"), :error)
      end

      unless @flash_array
        add_ems = model.model_from_emstype(@edit[:new][:emstype]).new
        set_record_vars(add_ems)
      end
      if !@flash_array && valid_record?(add_ems) && add_ems.save
        AuditEvent.success(build_created_audit(add_ems, @edit))
        session[:edit] = nil  # Clear the edit object from the session object
        javascript_redirect :action => 'show_list', :flash_msg => _("%{model} \"%{name}\" was saved") % {:model => ui_lookup(:tables => @table_name), :name => add_ems.name}
      else
        @in_a_form = true
        unless @flash_array
          @edit[:errors].each { |msg| add_flash(msg, :error) }
          add_ems.errors.each do |field, msg|
            add_flash("#{add_ems.class.human_attribute_name(field)} #{msg}", :error)
          end
        end
        drop_breadcrumb(:name => _("Add New %{table}") % {:table => ui_lookup(:table => @table_name)},
                        :url  => "/#{controller_name}/new")
        javascript_flash
      end
    when "validate"
      verify_ems = model.model_from_emstype(@edit[:new][:emstype]).new
      validate_credentials verify_ems
    end
  end

  def edit
    assert_privileges("#{permission_prefix}_edit")
    begin
      @ems = find_record_with_rbac(model, params[:id])
    rescue => err
      return redirect_to(:action      => @lastaction || "show_list",
                         :flash_msg   => err.message,
                         :flash_error => true)
    end
    set_form_vars
    @in_a_form = true
    session[:changed] = false
    drop_breadcrumb(:name => _("Edit %{object_type} '%{object_name}'") % {:object_type => ui_lookup(:tables => @table_name), :object_name => @ems.name},
                    :url  => "/#{controller_name}/#{@ems.id}/edit")
  end

  def update
    assert_privileges("#{permission_prefix}_edit")
    return unless load_edit("ems_edit__#{params[:id]}")
    get_form_vars
    case params[:button]
    when "cancel"   then update_button_cancel
    when "save"     then update_button_save
    when "reset"    then update_button_reset
    when "validate" then
      @changed = session[:changed]
      update_button_validate
    end
  end

  def update_button_cancel
    session[:edit] = nil  # clean out the saved info
    _model = model
    flash = _("Edit of %{model} \"%{name}\" was cancelled by the user") %
            {:model => ui_lookup(:model => _model.to_s), :name => @ems.name}
    js_args = {:action    => @lastaction,
               :id        => @ems.id,
               :display   => session[:ems_display],
               :flash_msg => flash,
               :record    => @ems
    }
    javascript_redirect(javascript_process_redirect_args(js_args))
  end
  private :update_button_cancel

  def edit_changed?
    @edit[:new] != @edit[:current]
  end

  def update_button_save
    changed = edit_changed?
    update_ems = find_record_with_rbac(model, params[:id])
    set_record_vars(update_ems)
    if valid_record?(update_ems) && update_ems.save
      update_ems.reload
      flash = _("%{model} \"%{name}\" was saved") %
              {:model => ui_lookup(:model => model.to_s), :name => update_ems.name}
      AuditEvent.success(build_saved_audit(update_ems, @edit))
      session[:edit] = nil  # clean out the saved info
      js_args = {:action => 'show', :id => @ems.id.to_s, :flash_msg => flash, :record => @ems}
      javascript_redirect(javascript_process_redirect_args(js_args))
      return
    else
      @edit[:errors].each { |msg| add_flash(msg, :error) }
      update_ems.errors.each do |field, msg|
        add_flash("#{field.to_s.capitalize} #{msg}", :error)
      end

      breadcrumb_url = "/#{controller_name}/edit/#{@ems.id}"

      breadcrumb_url = "/#{controller_name}/#{@ems.id}/edit" if restful_routed?(model)

      drop_breadcrumb(:name => _("Edit %{table} '%{name}'") % {:table => ui_lookup(:table => @table_name),
                                                               :name  => @ems.name},
                      :url  => breadcrumb_url)
      @in_a_form = true
      session[:changed] = changed
      @changed = true
      render_flash
    end
  end
  private :update_button_save

  def update_button_reset
    params[:edittype] = @edit[:edittype]    # remember the edit type
    add_flash(_("All changes have been reset"), :warning)
    @in_a_form = true
    set_verify_status
    session[:flash_msgs] = @flash_array.dup                 # Put msgs in session for next transaction
    javascript_redirect :action => 'edit', :id => @ems.id.to_s
  end
  private :update_button_reset

  def update_button_validate
    verify_ems = find_record_with_rbac(model, params[:id])
    validate_credentials verify_ems
  end
  private :update_button_validate

  def validate_credentials(verify_ems)
    set_record_vars(verify_ems, :validate)
    @in_a_form = true
    @changed = session[:changed]

    # validate button should say "revalidate" if the form is unchanged
    revalidating = !edit_changed?
    result, details = verify_ems.authentication_check(params[:type], :save => revalidating)
    if result
      add_flash(_("Credential validation was successful"))
    else
      add_flash(_("Credential validation was not successful: %{details}") % {:details => details}, :error)
    end

    render_flash
  end
  private :validate_credentials

  # handle buttons pressed on the button bar
  def button
    @edit = session[:edit]                                  # Restore @edit for adv search box

    params[:display] = @display if ["vms", "hosts", "storages", "instances", "images", "orchestration_stacks"].include?(@display)  # Were we displaying vms/hosts/storages
    params[:page] = @current_page unless @current_page.nil?   # Save current page for list refresh

    # Handle buttons from sub-items screen
    if params[:pressed].starts_with?("availability_zone_",
                                     "cloud_network_",
                                     "cloud_subnet_",
                                     "cloud_tenant_",
                                     "cloud_volume_",
                                     "ems_cluster_",
                                     "flavor_",
                                     "floating_ip_",
                                     "guest_",
                                     "host_",
                                     "image_",
                                     "instance_",
                                     "load_balancer_",
                                     "miq_template_",
                                     "network_port_",
                                     "network_router_",
                                     "orchestration_stack_",
                                     "security_group_",
                                     "storage_",
                                     "vm_")

      case params[:pressed]
      # Clusters
      when "ems_cluster_compare"              then comparemiq
      when "ems_cluster_delete"               then deleteclusters
      when "ems_cluster_protect"              then assign_policies(EmsCluster)
      when "ems_cluster_scan"                 then scanclusters
      when "ems_cluster_tag"                  then tag(EmsCluster)
      # Hosts
      when "host_analyze_check_compliance"    then analyze_check_compliance_hosts
      when "host_check_compliance"            then check_compliance_hosts
      when "host_compare"                     then comparemiq
      when "host_delete"                      then deletehosts
      when "host_edit"                        then edit_record
      when "host_protect"                     then assign_policies(Host)
      when "host_refresh"                     then refreshhosts
      when "host_scan"                        then scanhosts
      when "host_tag"                         then tag(Host)
      when "host_manageable"                  then sethoststomanageable
      when "host_introspect"                  then introspecthosts
      when "host_provide"                     then providehosts
      # Storages
      when "storage_delete"                   then deletestorages
      when "storage_refresh"                  then refreshstorage
      when "storage_scan"                     then scanstorage
      when "storage_tag"                      then tag(Storage)
      # Edit Tags for Network Manager Relationship pages
      when "availability_zone_tag"            then tag(AvailabilityZone)
      when "cloud_network_tag"                then tag(CloudNetwork)
      when "cloud_subnet_tag"                 then tag(CloudSubnet)
      when "cloud_tenant_tag"                 then tag(CloudTenant)
      when "cloud_volume_tag"                 then tag(CloudVolume)
      when "flavor_tag"                       then tag(Flavor)
      when "floating_ip_tag"                  then tag(FloatingIp)
      when "load_balancer_tag"                then tag(LoadBalancer)
      when "network_port_tag"                 then tag(NetworkPort)
      when "network_router_tag"               then tag(NetworkRouter)
      when "orchestration_stack_tag"          then tag(OrchestrationStack)
      when "security_group_tag"               then tag(SecurityGroup)
      end

      return if params[:pressed].include?("tag") && !%w(host_tag vm_tag miq_template_tag).include?(params[:pressed])
      pfx = pfx_for_vm_button_pressed(params[:pressed])
      # Handle Host power buttons
      if host_power_button?(params[:pressed])
        handle_host_power_button(params[:pressed])
      else
        process_vm_buttons(pfx)
        # Control transferred to another screen, so return
        return if ["host_tag", "#{pfx}_policy_sim", "host_scan", "host_refresh", "host_protect",
                   "host_compare", "#{pfx}_compare", "#{pfx}_tag", "#{pfx}_retire",
                   "#{pfx}_protect", "#{pfx}_ownership", "#{pfx}_refresh", "#{pfx}_right_size",
                   "#{pfx}_reconfigure", "storage_tag", "ems_cluster_compare",
                   "ems_cluster_protect", "ems_cluster_tag", "#{pfx}_resize", "#{pfx}_live_migrate",
                   "#{pfx}_evacuate"].include?(params[:pressed]) &&
                  @flash_array.nil?

        unless ["host_edit", "#{pfx}_edit", "#{pfx}_miq_request_new", "#{pfx}_clone",
                "#{pfx}_migrate", "#{pfx}_publish"].include?(params[:pressed])
          @refresh_div = "main_div"
          @refresh_partial = "layouts/gtl"
          show                                                        # Handle EMS buttons
        end
      end
    elsif params[:pressed].starts_with?("cloud_object_store_")
      case params[:pressed]
      when "cloud_object_store_container_new"
        return javascript_redirect(:controller => "cloud_object_store_container", :action => "new",
                                   :storage_manager_id => params[:id])
      else
        process_cloud_object_storage_buttons(params[:pressed])
      end
    else
      @refresh_div = "main_div" # Default div for button.rjs to refresh
      redirect_to :action => "new" if params[:pressed] == "new"
      deleteemss if params[:pressed] == "#{@table_name}_delete"
      refreshemss if params[:pressed] == "#{@table_name}_refresh"
      #     scanemss if params[:pressed] == "scan"
      tag(model) if params[:pressed] == "#{@table_name}_tag"

      # Edit Tags for Middleware Manager Relationship pages
      tag(@display.camelize.singularize) if @display && @display != 'main' &&
                                            params[:pressed] == "#{@display.singularize}_tag"
      assign_policies(model) if params[:pressed] == "#{@table_name}_protect"
      check_compliance(model) if params[:pressed] == "#{@table_name}_check_compliance"
      edit_record if params[:pressed] == "#{@table_name}_edit"
      if params[:pressed] == "#{@table_name}_timeline"
        @showtype = "timeline"
        @record = find_record_with_rbac(model, params[:id])
        @timeline = @timeline_filter = true
        @lastaction = "show_timeline"
        tl_build_timeline                       # Create the timeline report
        drop_breadcrumb(:name => _("Timelines"), :url => show_link(@record, :refresh => "n", :display => "timeline"))
        session[:tl_record_id] = @record.id
        javascript_redirect polymorphic_path(@record, :display => 'timeline')
        return
      end
      if params[:pressed] == "#{@table_name}_perf"
        @showtype = "performance"
        @record = find_record_with_rbac(model, params[:id])
        drop_breadcrumb(:name => _("%{name} Capacity & Utilization") % {:name => @record.name},
                        :url  => show_link(@record, :refresh => "n", :display => "performance"))
        perf_gen_init_options # Intialize options, charts are generated async
        javascript_redirect polymorphic_path(@record, :display => "performance")
        return
      end
      if params[:pressed] == "#{@table_name}_ad_hoc_metrics"
        @showtype = "ad_hoc_metrics"
        @record = find_record_with_rbac(model, params[:id])
        drop_breadcrumb(:name => @record.name + _(" (Ad hoc Metrics)"), :url => show_link(@record))
        javascript_redirect polymorphic_path(@record, :display => "ad_hoc_metrics")
        return
      end
      if params[:pressed] == "refresh_server_summary"
        javascript_redirect :back
        return
      end
      if params[:pressed] == "ems_cloud_recheck_auth_status"          ||
         params[:pressed] == "ems_infra_recheck_auth_status"          ||
         params[:pressed] == "ems_physical_infra_recheck_auth_status" ||
         params[:pressed] == "ems_middleware_recheck_auth_status"     ||
         params[:pressed] == "ems_container_recheck_auth_status"
        if params[:id]
          table_key = :table
          _result, details = recheck_authentication
          add_flash(_("Re-checking Authentication status for this %{controller_name} was not successful: %{details}") %
                        {:controller_name => ui_lookup(:table => controller_name), :details => details}, :error) if details
        else
          table_key = :tables
          ems_ids = find_checked_items
          ems_ids.each do |ems_id|
            _result, details = recheck_authentication(ems_id)
            add_flash(_("Re-checking Authentication status for the selected %{controller_name} %{name} was not successful: %{details}") %
                          {:controller_name => ui_lookup(:table => controller_name),
                           :name            => @record.name,
                           :details         => details}, :error) if details
          end
        end
        add_flash(_("Authentication status will be saved and workers will be restarted for the selected %{controller_name}") %
                      {:controller_name => ui_lookup(table_key => controller_name)})
        render_flash
        return
      end

      custom_buttons if params[:pressed] == "custom_button"

      return if ["custom_button"].include?(params[:pressed])    # custom button screen, so return, let custom_buttons method handle everything
      return if ["#{@table_name}_tag", "#{@table_name}_protect", "#{@table_name}_timeline"].include?(params[:pressed]) &&
                @flash_array.nil? # Tag screen showing, so return
      check_if_button_is_implemented
    end

    if !@flash_array.nil? && params[:pressed] == "#{@table_name}_delete" && @single_delete
      javascript_redirect :action      => 'show_list',
                          :flash_msg   => @flash_array[0][:message],
                          :flash_error => @flash_array[0][:level] == :error
    elsif params[:pressed] == "host_aggregate_edit"
      javascript_redirect :controller => "host_aggregate",
                          :action     => "edit",
                          :id         => find_checked_ids_with_rbac(HostAggregate).first
    elsif params[:pressed] == "cloud_tenant_edit"
      javascript_redirect :controller => "cloud_tenant",
                          :action     => "edit",
                          :id         => find_checked_ids_with_rbac(CloudTenant).first
    elsif params[:pressed] == "cloud_volume_new"
      javascript_redirect :controller         => "cloud_volume",
                          :action             => "new",
                          :storage_manager_id => params[:id]
    elsif params[:pressed] == "cloud_volume_snapshot_create"
      javascript_redirect :controller => "cloud_volume",
                          :action     => "snapshot_new",
                          :id         => find_checked_ids_with_rbac(CloudVolume).first
    elsif params[:pressed] == "cloud_volume_attach"
      javascript_redirect :controller => "cloud_volume",
                          :action     => "attach",
                          :id         => find_checked_ids_with_rbac(CloudVolume).first
    elsif params[:pressed] == "cloud_volume_detach"
      javascript_redirect :controller => "cloud_volume",
                          :action     => "detach",
                          :id         => find_checked_ids_with_rbac(CloudVolume).first
    elsif params[:pressed] == "cloud_volume_edit"
      javascript_redirect :controller => "cloud_volume",
                          :action     => "edit",
                          :id         => find_checked_ids_with_rbac(CloudVolume).first
    elsif params[:pressed] == "cloud_volume_delete"
      # Clear CloudVolumeController's lastaction, since we are calling the delete_volumes from
      # an external controller. This will ensure that the final redirect is properly handled.
      session["#{CloudVolumeController.session_key_prefix}_lastaction".to_sym] = nil
      javascript_redirect :controller      => "cloud_volume",
                          :action          => "delete_volumes",
                          :miq_grid_checks => params[:miq_grid_checks]
    elsif params[:pressed] == "network_router_edit"
      javascript_redirect :controller => "network_router",
                          :action     => "edit",
                          :id         => find_checked_ids_with_rbac(NetworkRouter).first
    elsif params[:pressed] == "network_router_add_interface"
      javascript_redirect :controller => "network_router",
                          :action     => "add_interface_select",
                          :id         => find_checked_ids_with_rbac(NetworkRouter).first
    elsif params[:pressed] == "network_router_remove_interface"
      javascript_redirect :controller => "network_router",
                          :action     => "remove_interface_select",
                          :id         => find_checked_ids_with_rbac(NetworkRouter).first
    elsif params[:pressed].ends_with?("_edit") || ["#{pfx}_miq_request_new", "#{pfx}_clone",
                                                   "#{pfx}_migrate", "#{pfx}_publish"].include?(params[:pressed])
      render_or_redirect_partial(pfx)
    else
      if @refresh_div == "main_div" && @lastaction == "show_list"
        replace_gtl_main_div
      else
        render_flash unless performed?
      end
    end
  end

  def recheck_authentication(id = nil)
    @record = find_record_with_rbac(model, id || params[:id])
    @record.authentication_check_types_queue(@record.authentication_for_summary.pluck(:authtype), :save => true)
  end

  def check_compliance(model)
    showlist = @lastaction == "show_list"
    ids = showlist ? find_checked_ids_with_rbac(model) : find_id_with_rbac(model, [params[:id]])
    if ids.blank?
      add_flash(_("No %{model} were selected for Compliance Check") % {:model => ui_lookup(:models => model.to_s)}, :error)
    end
    process_emss(ids, "check_compliance")
    params[:display] = "main"
    showlist ? show_list : show
  end

  private ############################

  def generate_breadcrumb(name, url, replace = false)
    drop_breadcrumb({:name => name, :url => url}, replace)
  end

  def set_verify_status
    edit_new = @edit[:new]
    if edit_new[:emstype] == "ec2"
      if edit_new[:default_userid].blank? || edit_new[:provider_region].blank?
        @edit[:default_verify_status] = false
      else
        @edit[:default_verify_status] = (edit_new[:default_password] == edit_new[:default_verify])
      end
    else
      if edit_new[:default_userid].blank? || edit_new[:hostname].blank? || edit_new[:emstype].blank?
        @edit[:default_verify_status] = false
      else
        @edit[:default_verify_status] = (edit_new[:default_password] == edit_new[:default_verify])
      end
    end

    if edit_new[:metrics_userid].blank? || edit_new[:hostname].blank? || edit_new[:emstype].blank?
      @edit[:metrics_verify_status] = false
    else
      @edit[:metrics_verify_status] = (edit_new[:metrics_password] == edit_new[:metrics_verify])
    end

    if edit_new[:bearer_token].blank? || edit_new[:hostname].blank? || edit_new[:emstype].blank?
      @edit[:bearer_verify_status] = false
    else
      @edit[:bearer_verify_status] = true
    end

    # check if any of amqp_userid, amqp_password, amqp_verify, :hostname, :emstype are blank
    if any_blank_fields?(edit_new, [:amqp_userid, :amqp_password, :amqp_verify, :hostname, :emstype])
      @edit[:amqp_verify_status] = false
    else
      @edit[:amqp_verify_status] = (edit_new[:amqp_password] == edit_new[:amqp_verify])
    end
  end

  # Validate the ems record fields
  def valid_record?(ems)
    @edit[:errors] = []
    if ems.emstype == "scvmm" && ems.security_protocol == "kerberos" && ems.realm.blank?
      add_flash(_("Realm is required"), :error)
    end
    if !ems.authentication_password.blank? && ems.authentication_userid.blank?
      @edit[:errors].push(_("Username must be entered if Password is entered"))
    end
    if @edit[:new][:password] != @edit[:new][:verify]
      @edit[:errors].push(_("Password/Verify Password do not match"))
    end
    if ems.supports_authentication?(:metrics) && @edit[:new][:metrics_password] != @edit[:new][:metrics_verify]
      @edit[:errors].push(_("C & U Database Login Password and Verify Password fields do not match"))
    end
    if ems.kind_of?(ManageIQ::Providers::Vmware::InfraManager)
      unless @edit[:new][:host_default_vnc_port_start] =~ /^\d+$/ || @edit[:new][:host_default_vnc_port_start].blank?
        @edit[:errors].push(_("Default Host VNC Port Range Start must be numeric"))
      end
      unless @edit[:new][:host_default_vnc_port_end] =~ /^\d+$/ || @edit[:new][:host_default_vnc_port_end].blank?
        @edit[:errors].push(_("Default Host VNC Port Range End must be numeric"))
      end
      unless (@edit[:new][:host_default_vnc_port_start].blank? &&
          @edit[:new][:host_default_vnc_port_end].blank?) ||
             (!@edit[:new][:host_default_vnc_port_start].blank? &&
                 !@edit[:new][:host_default_vnc_port_end].blank?)
        @edit[:errors].push(_("To configure the Host Default VNC Port Range, both start and end ports are required"))
      end
      if !@edit[:new][:host_default_vnc_port_start].blank? &&
         !@edit[:new][:host_default_vnc_port_end].blank?
        if @edit[:new][:host_default_vnc_port_end].to_i < @edit[:new][:host_default_vnc_port_start].to_i
          @edit[:errors].push(_("The Host Default VNC Port Range ending port must be equal to or higher than the starting point"))
        end
      end
    end
    @edit[:errors].empty?
  end

  # Set form variables for edit
  def set_form_vars
    form_instance_vars

    @edit = {}
    @edit[:ems_id] = @ems.id
    @edit[:key] = "ems_edit__#{@ems.id || "new"}"
    @edit[:new] = {}
    @edit[:current] = {}

    @edit[:new][:name] = @ems.name
    @edit[:new][:provider_region] = @ems.provider_region
    @edit[:new][:hostname] = @ems.hostname
    @edit[:new][:emstype] = @ems.emstype
    @edit[:new][:port] = @ems.port
    @edit[:new][:api_version] = @ems.api_version
    @edit[:new][:provider_id] = @ems.provider_id

    if @ems.kind_of?(ManageIQ::Providers::Openstack::CloudManager) ||
       @ems.kind_of?(ManageIQ::Providers::Openstack::InfraManager)
      # Special behaviour for OpenStack while keeping it backwards compatible for the rest
      @edit[:protocols] = retrieve_openstack_security_protocols
    else
      @edit[:protocols] = [['Basic (SSL)', 'ssl'], ['Kerberos', 'kerberos']]
    end

    if @ems.kind_of?(ManageIQ::Providers::Openstack::CloudManager) ||
       @ems.kind_of?(ManageIQ::Providers::Openstack::InfraManager)
      # Special behaviour for OpenStack while keeping it backwards compatible for the rest
      @edit[:new][:default_security_protocol] = @ems.security_protocol ? @ems.security_protocol : 'ssl'
    else
      if @ems.id
        # for existing provider before this fix, set default to ssl
        @edit[:new][:default_security_protocol] = @ems.security_protocol ? @ems.security_protocol : 'ssl'
      else
        @edit[:new][:default_security_protocol] = 'kerberos'
      end
    end

    @edit[:new][:realm] = @ems.realm if @edit[:new][:emstype] == "scvmm"
    if @ems.zone.nil? || @ems.my_zone == ""
      @edit[:new][:zone] = "default"
    else
      @edit[:new][:zone] = @ems.my_zone
    end

    @edit[:server_zones] = Zone.order('lower(description)').collect { |z| [z.description, z.name] }

    @edit[:openstack_infra_providers] = ManageIQ::Providers::Openstack::Provider.order('lower(name)').each_with_object([["---", nil]]) do |openstack_infra_provider, x|
      x.push([openstack_infra_provider.name, openstack_infra_provider.id])
    end

    @edit[:openstack_api_versions] = retrieve_openstack_api_versions
    @edit[:nuage_api_versions]     = retrieve_nuage_api_versions
    @edit[:vmware_cloud_api_versions] = retrieve_vmware_cloud_api_versions

    @edit[:new][:default_userid] = @ems.authentication_userid
    @edit[:new][:default_password] = @ems.authentication_password
    @edit[:new][:default_verify] = @ems.authentication_password

    @edit[:new][:metrics_userid] = @ems.has_authentication_type?(:metrics) ? @ems.authentication_userid(:metrics).to_s : ""
    @edit[:new][:metrics_password] = @ems.has_authentication_type?(:metrics) ? @ems.authentication_password(:metrics).to_s : ""
    @edit[:new][:metrics_verify] = @ems.has_authentication_type?(:metrics) ? @ems.authentication_password(:metrics).to_s : ""

    @edit[:new][:amqp_userid] = @ems.has_authentication_type?(:amqp) ? @ems.authentication_userid(:amqp).to_s : ""
    @edit[:new][:amqp_password] = @ems.has_authentication_type?(:amqp) ? @ems.authentication_password(:amqp).to_s : ""
    @edit[:new][:amqp_verify] = @ems.has_authentication_type?(:amqp) ? @ems.authentication_password(:amqp).to_s : ""

    @edit[:new][:ssh_keypair_userid] = @ems.has_authentication_type?(:ssh_keypair) ? @ems.authentication_userid(:ssh_keypair).to_s : ""
    @edit[:new][:ssh_keypair_password] = @ems.has_authentication_type?(:ssh_keypair) ? @ems.authentication_key(:ssh_keypair).to_s : ""

    @edit[:new][:bearer_token] = @ems.has_authentication_type?(:bearer) ? @ems.authentication_token(:bearer).to_s : ""
    @edit[:new][:bearer_verify] = @ems.has_authentication_type?(:bearer) ? @ems.authentication_token(:bearer).to_s : ""

    if @ems.kind_of?(ManageIQ::Providers::Vmware::InfraManager)
      @edit[:new][:host_default_vnc_port_start] = @ems.host_default_vnc_port_start.to_s
      @edit[:new][:host_default_vnc_port_end] = @ems.host_default_vnc_port_end.to_s
    end
    @edit[:ems_types] = model.supported_types_and_descriptions_hash
    @edit[:saved_default_verify_status] = nil
    @edit[:saved_metrics_verify_status] = nil
    @edit[:saved_bearer_verify_status] = nil
    @edit[:saved_amqp_verify_status] = nil
    set_verify_status

    @edit[:current] = @edit[:new].dup
    session[:edit] = @edit
  end

  def form_instance_vars
    @server_zones = []
    zones = Zone.order('lower(description)')
    zones.each do |zone|
      @server_zones.push([zone.description, zone.name])
    end
    @ems_types = Array(model.supported_types_and_descriptions_hash.invert).sort_by(&:first)

    @provider_regions = retrieve_provider_regions
    @openstack_infra_providers = retrieve_openstack_infra_providers
    @openstack_security_protocols = retrieve_openstack_security_protocols
    @amqp_security_protocols = retrieve_amqp_security_protocols
    @nuage_security_protocols = retrieve_nuage_security_protocols
    @container_security_protocols = retrieve_container_security_protocols
    @scvmm_security_protocols = [[_('Basic (SSL)'), 'ssl'], ['Kerberos', 'kerberos']]
    @openstack_api_versions = retrieve_openstack_api_versions
    @vmware_cloud_api_versions = retrieve_vmware_cloud_api_versions
    @emstype_display = model.supported_types_and_descriptions_hash[@ems.emstype]
    @nuage_api_versions = retrieve_nuage_api_versions
    @hawkular_security_protocols = retrieve_hawkular_security_protocols
  end

  def retrieve_provider_regions
    managers = model.supported_subclasses.select(&:supports_regions?)
    managers.each_with_object({}) do |manager, provider_regions|
      regions = manager.parent::Regions.all.sort_by { |r| r[:description] }
      provider_regions[manager.ems_type] = regions.map do |region|
        [region[:description], region[:name]]
      end
    end
  end
  private :retrieve_provider_regions

  def retrieve_openstack_infra_providers
    ManageIQ::Providers::Openstack::Provider.pluck(:name, :id)
  end

  def retrieve_openstack_api_versions
    [['Keystone v2', 'v2'], ['Keystone v3', 'v3']]
  end

  def retrieve_vmware_cloud_api_versions
    [['vCloud API 5.1', '5.1'], ['vCloud API 5.5', '5.5'], ['vCloud API 5.6', '5.6'], ['vCloud API 9.0', '9.0']]
  end

  def retrieve_nuage_api_versions
    [['Version 3.2', 'v3_2'], ['Version 4.0', 'v4_0']]
  end

  def retrieve_security_protocols
    [[_('SSL without validation'), 'ssl'], [_('SSL'), 'ssl-with-validation'], [_('Non-SSL'), 'non-ssl']]
  end

  def retrieve_openstack_security_protocols
    retrieve_security_protocols
  end

  def retrieve_nuage_security_protocols
    retrieve_security_protocols
  end

  def retrieve_amqp_security_protocols
    # OSP8 doesn't support SSL for AMQP
    [[_('Non-SSL'), 'non-ssl']]
  end

  def retrieve_container_security_protocols
    [[_('SSL'), 'ssl-with-validation'],
     [_('SSL trusting custom CA'), 'ssl-with-validation-custom-ca'],
     [_('SSL without validation'), 'ssl-without-validation']]
  end

  def retrieve_hawkular_security_protocols
    [[_('SSL'), 'ssl-with-validation'],
     [_('SSL trusting custom CA'), 'ssl-with-validation-custom-ca'],
     [_('SSL without validation'), 'ssl-without-validation'],
     [_('Non-SSL'), 'non-ssl']]
  end

  # Get variables from edit form
  def get_form_vars
    @ems = @edit[:ems_id] ? model.find_by_id(@edit[:ems_id]) : model.new

    @edit[:new][:name] = params[:name] if params[:name]
    @edit[:new][:ipaddress] = @edit[:new][:hostname] = "" if params[:server_emstype]
    @edit[:new][:provider_region] = params[:provider_region] if params[:provider_region]
    @edit[:new][:hostname] = params[:hostname] if params[:hostname]
    if params[:server_emstype]
      @edit[:new][:provider_region] = @ems.provider_region
      @edit[:new][:emstype] = params[:server_emstype]
      if ["openstack", "openstack_infra"].include?(params[:server_emstype])
        @edit[:new][:port] = @ems.port ? @ems.port : 5000
        @edit[:new][:api_version] = @ems.api_version ? @ems.api_version : 'v2'
        @edit[:new][:default_security_protocol] = @ems.security_protocol ? @ems.security_protocol : 'ssl'
      elsif params[:server_emstype] == ManageIQ::Providers::Kubernetes::ContainerManager.ems_type
        @edit[:new][:port] = @ems.port ? @ems.port : ManageIQ::Providers::Kubernetes::ContainerManager::DEFAULT_PORT
      elsif params[:server_emstype] == ManageIQ::Providers::Openshift::ContainerManager.ems_type
        @edit[:new][:port] = @ems.port ? @ems.port : ManageIQ::Providers::Openshift::ContainerManager::DEFAULT_PORT
      else
        @edit[:new][:port] = nil
      end

      if ["openstack", "openstack_infra"].include?(params[:server_emstype])
        @edit[:protocols] = retrieve_openstack_security_protocols
      else
        @edit[:protocols] = [[_('Basic (SSL)'), 'ssl'], ['Kerberos', 'kerberos']]
      end
    end
    @edit[:new][:port] = params[:port] if params[:port]
    @edit[:new][:api_version] = params[:api_version] if params[:api_version]
    @edit[:new][:provider_id] = params[:provider_id] if params[:provider_id]
    @edit[:new][:zone] = params[:server_zone] if params[:server_zone]

    @edit[:new][:default_userid] = params[:default_userid] if params[:default_userid]
    @edit[:new][:default_password] = params[:default_password] if params[:default_password]
    @edit[:new][:default_verify] = params[:default_verify] if params[:default_verify]

    @edit[:new][:metrics_userid] = params[:metrics_userid] if params[:metrics_userid]
    @edit[:new][:metrics_password] = params[:metrics_password] if params[:metrics_password]
    @edit[:new][:metrics_verify] = params[:metrics_verify] if params[:metrics_verify]

    @edit[:new][:amqp_userid] = params[:amqp_userid] if params[:amqp_userid]
    @edit[:new][:amqp_password] = params[:amqp_password] if params[:amqp_password]
    @edit[:new][:amqp_verify] = params[:amqp_verify] if params[:amqp_verify]

    @edit[:new][:ssh_keypair_userid] = params[:ssh_keypair_userid] if params[:ssh_keypair_userid]
    @edit[:new][:ssh_keypair_password] = params[:ssh_keypair_password] if params[:ssh_keypair_password]

    @edit[:new][:bearer_token] = params[:bearer_token] if params[:bearer_token]
    @edit[:new][:bearer_verify] = params[:bearer_verify] if params[:bearer_verify]

    @edit[:new][:host_default_vnc_port_start] = params[:host_default_vnc_port_start] if params[:host_default_vnc_port_start]
    @edit[:new][:host_default_vnc_port_end] = params[:host_default_vnc_port_end] if params[:host_default_vnc_port_end]
    @edit[:new][:default_security_protocol] = params[:default_security_protocol] if params[:default_security_protocol]
    # TODO: (julian) Silly hack until we move Infra over to Angular to be consistant with Cloud
    @edit[:new][:default_security_protocol] = params[:security_protocol] if params[:security_protocol]
    @edit[:new][:amqp_security_protocol] = params[:amqp_security_protocol] if params[:amqp_security_protocol]
    @edit[:new][:realm] = nil if params[:default_security_protocol]
    @edit[:new][:realm] = params[:realm] if params[:realm]
    restore_password if params[:restore_password]
    set_verify_status
  end

  # Set record variables to new values
  def set_record_vars(ems, mode = nil)
    ems.name = @edit[:new][:name]
    ems.provider_region = @edit[:new][:provider_region]
    ems.hostname = @edit[:new][:hostname].strip unless @edit[:new][:hostname].nil?
    ems.port = @edit[:new][:port] if ems.supports_port?
    ems.api_version = @edit[:new][:api_version] if ems.supports_api_version?
    ems.security_protocol = @edit[:new][:default_security_protocol] if ems.supports_security_protocol?
    ems.provider_id = @edit[:new][:provider_id] if ems.supports_provider_id?
    ems.zone = Zone.find_by_name(@edit[:new][:zone])

    if ems.kind_of?(ManageIQ::Providers::Microsoft::InfraManager)
      # TODO should be refactored to support methods, although there seems to be no UI for Microsoft provider
      # TODO: (julian) Silly hack until we move Infra over to Angular to be consistant with Cloud
      ems.security_protocol = @edit[:new][:default_security_protocol]
      ems.realm = @edit[:new][:realm]
    end

    if ems.kind_of?(ManageIQ::Providers::Vmware::InfraManager)
      ems.host_default_vnc_port_start = @edit[:new][:host_default_vnc_port_start].blank? ? nil : @edit[:new][:host_default_vnc_port_start].to_i
      ems.host_default_vnc_port_end = @edit[:new][:host_default_vnc_port_end].blank? ? nil : @edit[:new][:host_default_vnc_port_end].to_i
    end

    creds = {}
    creds[:default] = {:userid => @edit[:new][:default_userid], :password => @edit[:new][:default_password]} unless @edit[:new][:default_userid].blank?
    if ems.supports_authentication?(:metrics) && !@edit[:new][:metrics_userid].blank?
      creds[:metrics] = {:userid => @edit[:new][:metrics_userid], :password => @edit[:new][:metrics_password]}
    end
    if ems.supports_authentication?(:amqp) && !@edit[:new][:amqp_userid].blank?
      creds[:amqp] = {:userid => @edit[:new][:amqp_userid], :password => @edit[:new][:amqp_password]}
    end
    if ems.supports_authentication?(:ssh_keypair) && !@edit[:new][:ssh_keypair_userid].blank?
      creds[:ssh_keypair] = {:userid => @edit[:new][:ssh_keypair_userid], :auth_key => @edit[:new][:ssh_keypair_password]}
    end
    if ems.supports_authentication?(:bearer) && !@edit[:new][:bearer_token].blank?
      creds[:bearer] = {:auth_key => @edit[:new][:bearer_token]}
    end
    if ems.supports_authentication?(:auth_key) && !@edit[:new][:service_account].blank?
      creds[:default] = {:auth_key => @edit[:new][:service_account], :userid => "_"}
    end
    ems.update_authentication(creds, :save => (mode != :validate))
  end

  def process_emss(emss, task)
    emss, _emss_out_region = filter_ids_in_region(emss, "Provider")
    assert_rbac(model, emss)

    return if emss.empty?

    if task == "refresh_ems"
      model.refresh_ems(emss, true)
      add_flash(n_("%{task} initiated for %{count} %{model} from the %{product} Database",
                   "%{task} initiated for %{count} %{models} from the %{product} Database", emss.length) % \
        {:task    => task_name(task).gsub("Ems", ui_lookup(:tables => @table_name)),
         :count   => emss.length,
         :product => I18n.t('product.name'),
         :model   => ui_lookup(:table => @table_name),
         :models  => ui_lookup(:tables => @table_name)})
      AuditEvent.success(:userid => session[:userid], :event => "#{@table_name}_#{task}",
          :message => _("'%{task}' successfully initiated for %{table}") %
            {:task => task, :table => pluralize(emss.length, ui_lookup(:tables => @table_name).to_s)},
          :target_class => model.to_s)
    elsif task == "destroy"
      model.where(:id => emss).order("lower(name)").each do |ems|
        id = ems.id
        ems_name = ems.name
        audit = {:event        => "ems_record_delete_initiated",
                 :message      => _("[%{name}] Record delete initiated") % {:name => ems_name},
                 :target_id    => id,
                 :target_class => model.to_s,
                 :userid       => session[:userid]}
        AuditEvent.success(audit)
      end
      model.destroy_queue(emss)
      add_flash(n_("Delete initiated for %{count} %{model} from the %{product} Database",
                   "Delete initiated for %{count} %{models} from the %{product} Database", emss.length) %
        {:count   => emss.length,
         :product => I18n.t('product.name'),
         :model   => ui_lookup(:table => @table_name),
         :models  => ui_lookup(:tables => @table_name)}) if @flash_array.nil?
    else
      model.where(:id => emss).order("lower(name)").each do |ems|
        id = ems.id
        ems_name = ems.name
        begin
          ems.send(task.to_sym) if ems.respond_to?(task)    # Run the task
        rescue => bang
          add_flash(_("%{model} \"%{name}\": Error during '%{task}': %{error_message}") %
            {:model => model.to_s, :name => ems_name, :task => task, :error_message => bang.message}, :error)
          AuditEvent.failure(:userid => session[:userid], :event => "#{@table_name}_#{task}",
            :message      => _("%{name}: Error during '%{task}': %{message}") %
                          {:name => ems_name, :task => task, :message => bang.message},
            :target_class => model.to_s, :target_id => id)
        else
          add_flash(_("%{model} \"%{name}\": %{task} successfully initiated") % {:model => model.to_s, :name => ems_name, :task => task})
          AuditEvent.success(:userid => session[:userid], :event => "#{@table_name}_#{task}",
                             :message      => _("%{name}: '%{task}' successfully initiated") % {:name => ems_name, :task => task},
                             :target_class => model.to_s, :target_id => id)
        end
      end
    end
  end

  # Delete all selected or single displayed ems(s)
  def deleteemss
    assert_privileges(params[:pressed])
    emss = []
    if @lastaction == "show_list" # showing a list, scan all selected emss
      emss = find_checked_items
      if emss.empty?
        add_flash(_("No %{record} were selected for deletion") % {:record => ui_lookup(:table => @table_name)}, :error)
      end
      process_emss(emss, "destroy") unless emss.empty?
      add_flash(n_("Delete initiated for %{count} %{model} from the %{product} Database",
                   "Delete initiated for %{count} %{models} from the %{product} Database", emss.length) %
        {:count   => emss.length,
         :product => I18n.t('product.name'),
         :model   => ui_lookup(:table => @table_name),
         :models  => ui_lookup(:tables => @table_name)}) if @flash_array.nil?
    else # showing 1 ems, scan it
      if params[:id].nil? || model.find_by_id(params[:id]).nil?
        add_flash(_("%{record} no longer exists") % {:record => ui_lookup(:table => @table_name)}, :error)
      else
        emss.push(params[:id])
      end
      process_emss(emss, "destroy") unless emss.empty?
      @single_delete = true unless flash_errors?
      add_flash(_("The selected %{record} was deleted") %
        {:record => ui_lookup(:tables => @table_name)}) if @flash_array.nil?
    end
    if @lastaction == "show_list"
      show_list
      @refresh_partial = "layouts/gtl"
    end
  end

  # Scan all selected or single displayed ems(s)
  def scanemss
    assert_privileges(params[:pressed])
    emss = []
    if @lastaction == "show_list" # showing a list, scan all selected emss
      emss = find_checked_items
      if emss.empty?
        add_flash(_("No %{model} were selected for scanning") % {:model => ui_lookup(:table => @table_name)}, :error)
      end
      process_emss(emss, "scan")  unless emss.empty?
      add_flash(n_("Analysis initiated for %{count} %{model} from the %{product} Database",
                   "Analysis initiated for %{count} %{models} from the %{product} Database", emss.length) %
        {:count   => emss.length,
         :product => I18n.t('product.name'),
         :model   => ui_lookup(:table => @table_name),
         :models  => ui_lookup(:tables => @table_name)}) if @flash_array.nil?
      show_list
      @refresh_partial = "layouts/gtl"
    else # showing 1 ems, scan it
      if params[:id].nil? || model.find_by_id(params[:id]).nil?
        add_flash(_("%{record} no longer exists") % {:record => ui_lookup(:tables => @table_name)}, :error)
      else
        emss.push(params[:id])
      end
      process_emss(emss, "scan")  unless emss.empty?
      add_flash(n_("Analysis initiated for %{count} %{model} from the %{product} Database",
                   "Analysis initiated for %{count} %{models} from the %{product} Database", emss.length) %
        {:count   => emss.length,
         :product => I18n.t('product.name'),
         :model   => ui_lookup(:table => @table_name),
         :models  => ui_lookup(:tables => @table_name)}) if @flash_array.nil?
      params[:display] = @display
      show
      if ["vms", "hosts", "storages"].include?(@display)
        @refresh_partial = "layouts/gtl"
      else
        @refresh_partial = "main"
      end
    end
  end

  def call_ems_refresh(emss)
    process_emss(emss, "refresh_ems") unless emss.empty?
    return if @flash_array.present?

    add_flash(n_("Refresh initiated for %{count} %{model} from the %{product} Database",
                 "Refresh initiated for %{count} %{models} from the %{product} Database", emss.length) %
      {:count   => emss.length,
       :product => I18n.t('product.name'),
       :model   => ui_lookup(:table => @table_name),
       :models  => ui_lookup(:tables => @table_name)})
  end

  # Refresh VM states for all selected or single displayed ems(s)
  def refreshemss
    assert_privileges(params[:pressed])
    if @lastaction == "show_list"
      emss = find_checked_items
      if emss.empty?
        add_flash(_("No %{model} were selected for refresh") % {:model => ui_lookup(:table => @table_name)}, :error)
      end
      call_ems_refresh(emss)
      show_list
      @refresh_partial = "layouts/gtl"
    else
      if params[:id].nil? || model.find_by_id(params[:id]).nil?
        add_flash(_("%{record} no longer exists") % {:record => ui_lookup(:table => @table_name)}, :error)
      else
        call_ems_refresh([params[:id]])
      end
      params[:display] = @display
    end
  end

  # true, if any of the given fields are either missing from or blank in hash
  def any_blank_fields?(hash, fields)
    fields = [fields] unless fields.kind_of? Array
    fields.any? { |f| hash[f].blank? }
  end

  def model
    self.class.model
  end

  def permission_prefix
    self.class.permission_prefix
  end

  def show_list_link(ems, options = {})
    url_for_only_path(options.merge(:controller => controller_name,
                                    :action     => "show_list",
                                    :id         => ems.id))
  end

  def restore_password
    if params[:default_password]
      @edit[:new][:default_password] = @edit[:new][:default_verify] = @ems.authentication_password
    end
    if params[:amqp_password]
      @edit[:new][:amqp_password] = @edit[:new][:amqp_verify] = @ems.authentication_password(:amqp)
    end
    if params[:metrics_password]
      @edit[:new][:metrics_password] = @edit[:new][:metrics_verify] = @ems.authentication_password(:metrics)
    end
    if params[:bearer_token]
      @edit[:new][:bearer_token] = @edit[:new][:bearer_verify] = @ems.authentication_token(:bearer)
    end
  end
end
