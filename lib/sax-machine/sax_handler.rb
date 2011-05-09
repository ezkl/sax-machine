require "nokogiri"

module SAXMachine
  class SAXHandler < Nokogiri::XML::SAX::Document
    attr_reader :stack

    def initialize(object)
      @stack = [[object, nil, ""]]
      @parsed_configs = []
    end

    # characters might be called multiple times according to docs
    def characters(string)
      if value = stack.last[2]
        value << string
      else
        stack.last.push(string)
      end
    end

    def cdata_block(string)
      characters(string)
    end

    def start_element(name, attrs = [])
      attrs.flatten!
      object, config, _ = stack.last
      sax_config = object.class.respond_to?(:sax_config) ? object.class.sax_config : nil
        
      if sax_config
        if collection_config = sax_config.collection_config(name, attrs)
          stack.push [object = collection_config.data_class.new, collection_config]
          sax_config = object.class.sax_config

          if (attribute_config = object.class.respond_to?(:sax_config) && object.class.sax_config.attribute_configs_for_element(attrs))
            attribute_config.each { |ac| object.send(ac.setter, ac.value_from_attrs(attrs)) }
          end
        end

        sax_config.element_configs_for_attribute(name, attrs).each do |ec|
          unless parsed_config?(object, ec)
            object.send(ec.setter, ec.value_from_attrs(attrs))
            mark_as_parsed(object, ec)
          end
        end

        if !collection_config && element_config = sax_config.element_config_for_tag(name, attrs)
          new_object = element_config.data_class ? element_config.data_class.new : object
          stack.push [new_object, element_config]

          if (attribute_config = new_object.class.respond_to?(:sax_config) && new_object.class.sax_config.attribute_configs_for_element(attrs))
            attribute_config.each { |ac| new_object.send(ac.setter, ac.value_from_attrs(attrs)) }
          end
        end
      end
    end

    def end_element(name)
      (object, tag_config, _), (element, config, value) = stack[-2..-1]
      return unless stack.size > 1 && config && config.name == name
      stack.pop

      unless parsed_config?(object, config)
        if (element_value_config = config.data_class.respond_to?(:sax_config) && config.data_class.sax_config.element_values_for_element)
          element_value_config.each { |evc| element.send(evc.setter, value) }
        end

        if config.respond_to?(:accessor)
          subconfig = element.class.sax_config if element.class.respond_to?(:sax_config)
          if econf = subconfig.element_config_for_tag(name,[])
            element.send(econf.setter, value) unless econf.value_configured?
          end
          object.send("add_#{config.accessor}", element)
        else
          if config.data_class
            tmp = value
            element.define_singleton_method(:inner_text) { tmp }
            value = element
          else
            value.define_singleton_method(:inner_text) { value }
          end
          object.send(config.setter, value) if value
          mark_as_parsed(object, config)
        end
      end
    end

    # @parsed_configs was originally a single hash that was never emptied- a memory leak
    # now we have an array where the next element represents the child of the previous
    # once we come back to a parent element, the child's hash should be removed
    def mark_as_parsed(object, element_config)
      return if element_config.collection?
      (@parsed_configs[stack.size] ||= {})[
        [object.object_id, element_config.object_id]
      ] = true
    end

    def parsed_config?(object, element_config)
      last_size = @stack_size || 0
      @stack_size = stack.size
      if @stack_size < last_size
        # free memory
        @parsed_configs.slice!(@stack_size + 1 .. -1)
      end
      h = @parsed_configs[@stack_size]
      h and h[[object.object_id, element_config.object_id]]
    end
  end
end
