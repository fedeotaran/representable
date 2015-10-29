require "forwardable"

module Representable
  class Config < ::Declarative::Definitions
    # Stores Definitions from ::property. It preserves the adding order (1.9+).
    # Same-named properties get overridden, just like in a Hash.
    #
    # Overwrite definition_class if you need a custom Definition object (helpful when using
    # representable in other gems).
    class Definitions < Hash
      def initialize(definition_class)
        @definition_class = definition_class
        super()
      end

      def add(name, options, &block)
        if options[:inherit] and parent_property = get(name) # i like that: the :inherit shouldn't be handled outside.
          return parent_property.merge!(options, &block)
        end
        options.delete(:inherit) # TODO: can we handle the :inherit in one single place?

        self[name.to_s] = @definition_class.new(name, options, &block)
      end


      def remove(name)
        delete(name.to_s)
      end

      extend Forwardable
      def_delegators :values, :each # so we look like an array. this is only used in Mapper. we could change that so we don't need to hide the hash.
    end

    # def initialize(definition_class=Definition)
    #   super()
    #   merge!(
    #     :definitions => @definitions  = Definitions.new(definition_class),
    #     :options     => @options      = {})
    # end
    attr_reader :options

    # extend Forwardable
    # def_delegators :@definitions, :get, :add, :each, :size, :remove
    def each(&block)
      values.each(&block)
    end

    def wrap=(value)
      value = value.to_s if value.is_a?(Symbol)
      self[:wrap] = Uber::Options::Value.new(value)
    end

    # Computes the wrap string or returns false.
    def wrap_for(represented, *args, &block)
      return unless self[:wrap]

      value = self[:wrap].evaluate(represented, *args)

      return value if value != true
      infer_name_for(represented.class.name)
    end

  private
    def infer_name_for(name)
      name.to_s.split('::').last.
       gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
       gsub(/([a-z\d])([A-Z])/,'\1_\2').
       downcase
    end
  end
end
