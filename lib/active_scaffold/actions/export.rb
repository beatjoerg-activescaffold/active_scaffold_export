module ActiveScaffold::Actions
  module Export
    def self.included(base)
      base.before_action :export_authorized?, :only => [:export]
      base.before_action :show_export_authorized?, :only => [:show_export]
    end

    # display the customization form or skip directly to export
    def show_export
      @export_config = active_scaffold_config.export
      respond_to do |wants|
        wants.html do
          render(:partial => 'show_export', :layout => true)
        end
        wants.js do
          render(:partial => 'show_export', :layout => false)
        end
      end
    end

    # if invoked directly, will use default configuration
    def export
      export_config = active_scaffold_config.export
      if params[:export_columns].nil?
        export_columns = {}
        export_config.columns.each { |col| export_columns[col.to_sym] = 1 }
        options = {
          :export_columns => export_columns,
          :full_download => export_config.default_full_download.to_s,
          :delimiter => export_config.default_delimiter,
          :skip_header => export_config.default_skip_header.to_s
        }
        params.merge!(options)
      end

      set_includes_for_columns(:export)
      @export_config = export_config
      # Make sure active_scaffold's find_page is dealing with the same list of
      # columns. Prevents an invalid SQL query when exporting after filtering
      # with field_search against a relation column, and that relation column is
      # not included in the set of export columns.
      @list_columns = @export_columns

      # this is required if you want this to work with IE
      if request.env['HTTP_USER_AGENT'] =~ /msie/i
        response.headers['Pragma'] = "public"
        response.headers['Cache-Control'] = "no-cache, must-revalidate, post-check=0, pre-check=0"
        response.headers['Expires'] = "0"
      end
      response.headers['Content-Disposition'] = "attachment; filename=#{export_file_name}"

      respond_to_action(:export)
    end

    protected

    def export_respond_to_csv
      response.headers['Content-type'] = Mime[:csv]
      # start streaming output
      self.response_body = Enumerator.new do |y|
        find_items_for_export do |records|
          @records = records
          str = render_to_string :partial => 'export', :layout => false, :formats => [:csv]
          y << str
          params[:skip_header] = 'true' # skip header on the next run
        end
      end
    end

    def export_respond_to_xlsx
      response.headers['Content-type'] = Mime[:xlsx]
      pkg = Axlsx::Package.new
      pkg.workbook.add_worksheet(name: worksheet_name) do |sheet|
        styles = @export_columns.collect { |column| view_context.export_column_header_style(column, :xlsx) }
        widths = @export_columns.map.with_index { |column, i| styles.dig(i, :width) || column.export_options&.dig(:xlsx, :width) || :auto }
        unless params[:skip_header]
          styles.map! { |style| pkg.workbook.styles.add_style style if style }
          sheet.add_row(@export_columns.collect { |column| view_context.format_export_column_header_name(column) }, style: styles, widths: widths)
        end
        find_items_for_export do |records|
          records.each do |record|
            row = []
            styles = []
            @export_columns.each do |column|
              data, style = view_context.get_export_column_value(record, column, :xlsx)
              style = pkg.workbook.styles.add_style style if style
              row << data
              styles << style
            end
            sheet.add_row row, style: styles, widths: widths
          end
        end
      end
      customize_xlsx(pkg)
      stream = pkg.to_stream # when adding rows to sheet, they won't pass to this stream if declared before. axlsx issue?
      self.response_body = Enumerator.new do |y|
        y << stream.read
      end
    end

    def worksheet_name(options = {})
      active_scaffold_config.label.
        gsub(/[#{Regexp.quote Axlsx::WORKSHEET_NAME_FORBIDDEN_CHARS.join}]/, options[:replace] || '-').
        truncate(Axlsx::WORKSHEET_MAX_NAME_LENGTH, options)
    end

    def customize_xlsx(package)
    end

    def export_columns
      return @export_columns if defined? @export_columns
      @export_columns = active_scaffold_config.export.columns.reject { |col| params[:export_columns][col.to_sym].nil? }
      sorting = active_scaffold_config.list.user&.sorting || active_scaffold_config.list.sorting
      sorting_columns = sorting.reject { |col, _| @export_columns.include?(col.name) }.map(&:first)
      @export_columns.map! { |col| active_scaffold_config.columns[col] }
      @export_columns += sorting_columns
    end

    # The actual algorithm to do the export
    def find_items_for_export(&block)
      find_options = { :sorting =>
        active_scaffold_config.list.user.sorting.nil? ?
          active_scaffold_config.list.sorting : active_scaffold_config.list.user.sorting,
        :pagination => true
      }
      do_search rescue nil
      params[:segment_id] = session[:segment_id]
      do_segment_search rescue nil

      if params[:full_download] == 'true'
        find_options.merge!({
          :per_page => 3000,
          :page => 1
        })
        find_page(find_options).pager.each do |page|
          yield page.items
        end
      else
        find_options.merge!({
          :pagination => active_scaffold_config.list.pagination,
          :per_page => active_scaffold_config.list.user.per_page,
          :page => active_scaffold_config.list.user.page
        })
        yield find_page(find_options).items
      end
    end

    # The default name of the downloaded file.
    # You may override the method to specify your own file name generation.
    def export_file_name
      filename = self.controller_name.clone

      if params[:format] && active_scaffold_config.export.formats.map(&:to_s).include?(params[:format])
        filename << ".#{params[:format]}"
      else
        filename << ".#{active_scaffold_config.export.default_file_format}"
      end

      return filename
    end

    # The default security delegates to ActiveRecordPermissions.
    # You may override the method to customize.
    def export_authorized?
      authorized_for?(:action => :read)
    end

    def show_export_authorized?
      export_authorized?
    end

    def export_formats
      active_scaffold_config.export.formats
    end

  end
end
