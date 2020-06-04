module PgSync
  class Sync
    include Utils

    def perform(options)
      args = options.arguments
      opts = options.to_hash
      @options = opts

      # only resolve commands from config, not CLI arguments
      [:to, :from].each do |opt|
        opts[opt] ||= resolve_source(config[opt.to_s])
      end

      # merge other config
      [:to_safe, :exclude, :schemas].each do |opt|
        opts[opt] ||= config[opt.to_s]
      end

      # TODO remove deprecations in 0.6.0
      map_deprecations(args, opts)

      # start
      start_time = Time.now

      if args.size > 2
        raise Error, "Usage:\n    pgsync [options]"
      end

      raise Error, "No source" unless source.exists?
      raise Error, "No destination" unless destination.exists?

      unless opts[:to_safe] || destination.local?
        raise Error, "Danger! Add `to_safe: true` to `.pgsync.yml` if the destination is not localhost or 127.0.0.1"
      end

      print_description("From", source)
      print_description("To", destination)

      tables = TableResolver.new(args, opts, source, config).tables

      # TODO uncomment for 0.6.0
      # if opts[:in_batches] && tables.size > 1
      #   raise Error, "Cannot use --in-batches with multiple tables"
      # end

      confirm_tables_exist(source, tables, "source")

      if opts[:list]
        confirm_tables_exist(destination, tables, "destination")

        list_items =
          if args[0] == "groups"
            (config["groups"] || {}).keys
          else
            tables.map { |t| t[:table] }
          end

        pretty_list list_items
      else
        if opts[:schema_first] || opts[:schema_only]
          if opts[:preserve]
            raise Error, "Cannot use --preserve with --schema-first or --schema-only"
          end

          log "* Dumping schema"
          schema_tables = tables if !opts[:all_schemas] || opts[:tables] || opts[:groups] || args[0] || opts[:exclude]
          SchemaSync.new(source: source, destination: destination, tables: schema_tables).perform
        end

        unless opts[:schema_only]
          confirm_tables_exist(destination, tables, "destination")

          # TODO query columns, sequences, primary keys, etc
          # for all tables at once and pass on initialization
          table_syncs =
            tables.map do |table|
              TableSync.new(source: source, destination: destination, config: config, table: table[:table], opts: opts.merge(table[:opts]))
            end

          # show notes before we start
          table_syncs.each do |ts|
            ts.notes.each do |note|
              warning "#{ts.table.sub("#{first_schema}.", "")}: #{note}"
            end
          end

          # don't sync tables with no shared fields
          # we show a warning message above
          table_syncs.reject! { |ts| ts.shared_fields.empty? }

          in_parallel(table_syncs) do |table_sync|
            table_sync.sync
          end
        end

        log_completed(start_time)
      end
    end

    def first_schema
      @first_schema ||= source.search_path.find { |sp| sp != "pg_catalog" }
    end

    def confirm_tables_exist(data_source, tables, description)
      tables.map { |t| t[:table] }.each do |table|
        unless data_source.table_exists?(table)
          raise Error, "Table does not exist in #{description}: #{table}"
        end
      end
    end

    def map_deprecations(args, opts)
      command = args[0]

      case command
      when "schema"
        args.shift
        opts[:schema_only] = true
        deprecated "Use `psync --schema-only` instead"
      when "tables"
        args.shift
        opts[:tables] = args.shift
        deprecated "Use `pgsync #{opts[:tables]}` instead"
      when "groups"
        args.shift
        opts[:groups] = args.shift
        deprecated "Use `pgsync #{opts[:groups]}` instead"
      end

      if opts[:where]
        opts[:sql] ||= String.new
        opts[:sql] << " WHERE #{opts[:where]}"
        deprecated "Use `\"WHERE #{opts[:where]}\"` instead"
      end

      if opts[:limit]
        opts[:sql] ||= String.new
        opts[:sql] << " LIMIT #{opts[:limit]}"
        deprecated "Use `\"LIMIT #{opts[:limit]}\"` instead"
      end
    end

    def config
      @config ||= begin
        file = config_file
        if file
          begin
            YAML.load_file(file) || {}
          rescue Psych::SyntaxError => e
            raise Error, e.message
          end
        else
          {}
        end
      end
    end

    def print_description(prefix, source)
      location = " on #{source.host}:#{source.port}" if source.host
      log "#{prefix}: #{source.dbname}#{location}"
    end

    def in_parallel(table_syncs, &block)
      spinners = TTY::Spinner::Multi.new(format: :dots, output: output)
      item_spinners = {}

      start = lambda do |item, i|
        message = ":spinner #{display_item(item)}"
        spinner = spinners.register(message)
        if @options[:in_batches]
          # log instead of spin for non-tty
          log message.sub(":spinner", "⠋")
        else
          spinner.auto_spin
        end
        item_spinners[item] = spinner
      end

      failed_tables = []

      finish = lambda do |item, i, result|
        spinner = item_spinners[item]
        result_message = display_result(result)

        if result[:status] == "success"
          spinner.success(result_message)
        else
          # TODO add option to fail fast
          spinner.error(result_message)
          failed_tables << item.table.sub("#{first_schema}.", "")
          fail_sync(failed_tables) if @options[:fail_fast]
        end

        unless spinner.send(:tty?)
          status = result[:status] == "success" ? "✔" : "✖"
          log [status, display_item(item), result_message].join(" ")
        end
      end

      options = {start: start, finish: finish}

      jobs = @options[:jobs]
      if @options[:debug] || @options[:in_batches] || @options[:defer_constraints]
        warning "--jobs ignored" if jobs
        jobs = 0
      end

      if windows?
        options[:in_threads] = jobs || 4
      else
        options[:in_processes] = jobs if jobs
      end

      maybe_defer_constraints do
        # could try to use `raise Parallel::Kill` to fail faster with --fail-fast
        # see `fast_faster` branch
        # however, need to make sure connections are cleaned up properly
        Parallel.each(table_syncs, **options) do |table_sync|
          # must reconnect for new thread or process
          # TODO only reconnect first time
          unless options[:in_processes] == 0
            source.reconnect
            destination.reconnect
          end

          # TODO warn if there are non-deferrable constraints on the table

          yield table_sync
        end
      end

      fail_sync(failed_tables) if failed_tables.any?
    end

    def maybe_defer_constraints
      if @options[:defer_constraints]
        destination.transaction do
          destination.execute("SET CONSTRAINTS ALL DEFERRED")

          # create a transaction on the source
          # to ensure we get a consistent snapshot
          source.transaction do
            yield
          end
        end
      else
        yield
      end
    end

    def fail_sync(failed_tables)
      raise Error, "Sync failed for #{failed_tables.size} table#{failed_tables.size == 1 ? nil : "s"}: #{failed_tables.join(", ")}"
    end

    def display_item(item)
      messages = []
      messages << item.table.sub("#{first_schema}.", "")
      messages << item.opts[:sql] if item.opts[:sql]
      messages.join(" ")
    end

    def display_result(result)
      messages = []
      messages << "- #{result[:time]}s" if result[:time]
      messages << "(#{result[:message].lines.first.to_s.strip})" if result[:message]
      messages.join(" ")
    end

    def pretty_list(items)
      items.each do |item|
        log item
      end
    end

    def log_completed(start_time)
      time = Time.now - start_time
      message = "Completed in #{time.round(1)}s"
      log colorize(message, :green)
    end

    def windows?
      Gem.win_platform?
    end

    def source
      @source ||= data_source(@options[:from])
    end

    def destination
      @destination ||= data_source(@options[:to])
    end

    def data_source(url)
      ds = DataSource.new(url)
      ObjectSpace.define_finalizer(self, self.class.finalize(ds))
      ds
    end

    def resolve_source(source)
      if source
        source = source.dup
        source.gsub!(/\$\([^)]+\)/) do |m|
          command = m[2..-2]
          result = `#{command}`.chomp
          unless $?.success?
            raise Error, "Command exited with non-zero status:\n#{command}"
          end
          result
        end
      end
      source
    end

    def self.finalize(ds)
      # must use proc instead of stabby lambda
      proc { ds.close }
    end
  end
end
