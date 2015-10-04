module Representable
  # The Binding wraps the Definition instance for this property and provides methods to read/write fragments.

  # The flow when parsing is Binding#read_fragment -> Populator -> Deserializer.
  # Actual parsing the fragment from the document happens in Binding#read, everything after that is generic.
  #
  # Serialization: Serializer -> {frag}/[frag]/frag -> Binding#write
  class Binding
    class FragmentNotFound
    end

    def self.build(definition, *args)
      # DISCUSS: move #create_binding to this class?
      return definition.create_binding(*args) if definition[:binding]
      build_for(definition, *args)
    end

    def initialize(definition, parent_decorator)
      @definition       = definition
      @parent_decorator = parent_decorator # DISCUSS: where's this needed?

      # static options. do this once.
      @representable    = @definition.representable?
      @name             = @definition.name
      @skip_filters     = self[:readable]==false || self[:writeable]==false || self[:if] # Does this binding contain :if, :readable or :writeable settings?
      @getter           = @definition.getter
      @setter           = @definition.setter
      @array            = @definition.array?
      @typed            = @definition.typed?
      @has_default      = @definition.has_default?
    end

    attr_reader :user_options, :represented # TODO: make private/remove.

    # DISCUSS: an overall strategy to speed up option reads will come around 3.0.
    attr_reader :representable, :name, :getter, :setter, :array, :typed, :skip_filters, :has_default
    alias_method :representable?, :representable
    alias_method :array?, :array
    alias_method :typed?, :typed
    alias_method :skip_filters?, :skip_filters
    alias_method :has_default?, :has_default

    def as # DISCUSS: private?
      @as ||= evaluate_option(:as)
    end

    # Single entry points for rendering and parsing a property are #compile_fragment
    # and #uncompile_fragment in Mapper.
    #
    # DISCUSS:
    # currently, we need to call B#update! before compile_fragment/uncompile_fragment.
    # this will change to B#renderer(represented, options).call
    #                     B#parser  (represented, options).call
    # goal is to have two objects for 2 entirely different tasks.

    # Retrieve value and write fragment to the doc.
    def compile_fragment(doc)
      evaluate_option(:writer, doc) do
        value = render_filter(get, doc)
        write_fragment(doc, value)
      end
    end

    # Parse value from doc and update the model property.
    def uncompile_fragment(doc)
      options = {doc: doc, binding: self}
      options[:representable_options] = Options.new(self, user_options, represented, parent_decorator)

      parse_pipeline.(options)
    end

    def write_fragment(doc, value)
      value = default_for(value)

      return if skipable_empty_value?(value)

      render_fragment(value, doc)
    end

    def render_fragment(value, doc)
      fragment = serialize(value) { return } # render fragments of hash, xml, yaml.

      write(doc, fragment)
    end

    def get
      evaluate_option(:getter) do
        exec_context.send(getter)
      end
    end

    # DISCUSS: do we really need that?
    #   1.38      0.104     0.021     0.000     0.083    40001   Representable::Binding#representer_module_for
    #   1.13      0.044     0.017     0.000     0.027    40001   Representable::Binding#representer_module_for (with memoize).
    def representer_module_for(object, *args)
      # TODO: cache this!
      evaluate_option(:extend, object) # TODO: pass args? do we actually have args at the time this is called (compile-time)?
    end

    # Evaluate the option (either nil, static, a block or an instance method call) or
    # executes passed block when option not defined.
    def evaluate_option(name, *args)
      unless proc = @definition[name] # TODO: this could dispatch directly to the @definition using #send?
        return yield if block_given?
        return
      end

      # TODO: it would be better if user_options was nil per default and then we just don't pass it into lambdas.
      __options = self[:pass_options] ? Options.new(self, user_options, represented, parent_decorator) : user_options

      proc.(exec_context, *(args<<__options)) # from Uber::Options::Value.
    end
    def render_filter(value, doc)
      evaluate_option(:render_filter, value, doc) { value }
    end

    def evaluate_option_with_deprecation(name, options, *positional_arguments)
      unless proc = @definition[name]
        return yield if block_given?
        return
      end


      __options = if self[:pass_options]
        warn %{[Representable] The :pass_options option is deprecated. Please access environment objects via options[:binding].
  Learn more here: http://trailblazerb.org/gems/representable/upgrading-guide.html#pass-options}
        Options.new(self, user_options, represented, parent_decorator)
      else
        user_options
      end
      options[:user_options] = __options # TODO: always make this user_options in Representable 3.0.


      if proc.send(:proc?) or proc.send(:method?)
        arity = proc.instance_variable_get(:@value).arity if proc.send(:proc?)
        arity = exec_context.method(proc.instance_variable_get(:@value)).arity if proc.send(:method?)
        if arity  != 1
          warn %{[Representable] Positional arguments for `:#{name}` are deprecated. Please use options or keyword arguments.
  #{name}: ->(options) { options[:#{positional_arguments.join(" | :")}] } or
  #{name}: ->(#{positional_arguments.join(":, ")}:) {  }
  Learn more here: http://trailblazerb.org/gems/representable/upgrading-guide.html#positional-arguments
  }
          deprecated_args = []
          positional_arguments.each do |arg|
            next if arg == :index && options[:index].nil?
            deprecated_args << __options  and next if arg == :user_options# either hash or Options object.
            deprecated_args << options[arg]
          end

          return proc.(exec_context, *deprecated_args)
        end
      end

      proc.(exec_context, options)
    end

    def [](name)
      @definition[name]
    end

    #   1.55      0.031     0.022     0.000     0.009    60004   Representable::Binding#skipable_empty_value?
    #   1.51      0.030     0.022     0.000     0.008    60004   Representable::Binding#skipable_empty_value?
    # after polymorphism:
    # 1.44      0.031     0.022     0.000     0.009    60002   Representable::Binding#skipable_empty_value?
    def skipable_empty_value?(value)
      value.nil? and not self[:render_nil]
    end

    def default_for(value)
      return self[:default] if skipable_empty_value?(value)
      value
    end

    # Note: this method is experimental.
    def update!(represented, user_options)
      @represented = represented

      setup_user_options!(user_options)
      setup_exec_context!
    end

    attr_accessor :cached_representer

    def functions
      return self[:parse_pipeline].() if self[:parse_pipeline] # untested.

      if array?
        return [*default_init_functions, Collect[*default_fragment_functions], *default_post_functions]
      end

      [*default_init_functions, *default_fragment_functions, *default_post_functions]
    end

  private
    # TODO: move to Pipeline::Builder
    def default_init_functions
      functions = [ReadFragment, has_default? ? Default : StopOnNotFound]
      functions << OverwriteOnNil # include StopOnNil if you don't want to erase things.
      functions
    end

    def default_fragment_functions
      functions = [ReturnFragment] # TODO: why do we always need that?
      functions << SkipParse if self[:skip_parse]

      if typed?
        functions += [CreateObject, Prepare]
        functions << Deserialize if representable?
      end

      functions
    end

    def default_post_functions
      funcs = []
      funcs << ParseFilter if self[:parse_filter].any?
      funcs << Setter
    end

    def setup_user_options!(user_options)
      @user_options  = user_options
      # this is the propagated_options.
      @user_options  = user_options.merge(wrap: false) if self[:wrap] == false
    end

    #   1.80      0.066     0.027     0.000     0.039    30002   Representable::Binding#setup_exec_context!
    #   0.98      0.034     0.014     0.000     0.020    30002   Representable::Binding#setup_exec_context!
    def setup_exec_context!
      return @exec_context = @represented unless self[:exec_context]
      @exec_context = self             if self[:exec_context] == :binding
      @exec_context = parent_decorator if self[:exec_context] == :decorator
    end

    attr_reader :exec_context, :parent_decorator

    def serialize(object, &block)
      serializer.call(object, &block)
    end

    module Factories
      def serializer_class
        Serializer
      end

      def serializer
        @serializer ||= serializer_class.new(self)
      end

      def parse_pipeline
        @parse_pipeline ||= Pipeline[*functions]
      end
    end
    include Factories


    # Options instance gets passed to lambdas when pass_options: true.
    # This is considered the new standard way and should be used everywhere for forward-compat.
    Options = Struct.new(:binding, :user_options, :represented, :decorator)


    # generics for collection bindings.
    module Collection
    private
      def serializer_class
        Serializer::Collection
      end

      def skipable_empty_value?(value)
        # TODO: this can be optimized, again.
        return true if value.nil? and not self[:render_nil] # FIXME: test this without the "and"
        return true if self[:render_empty] == false and value and value.size == 0  # TODO: change in 2.0, don't render emtpy.
      end
    end

    # and the same for hashes.
    module Hash
    private
      def serializer_class
        Serializer::Hash
      end
    end
  end


  class DeserializeError < RuntimeError
  end
end
