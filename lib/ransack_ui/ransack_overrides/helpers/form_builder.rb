require 'ransack/helpers/form_builder'

module Ransack
  module Helpers
    FormBuilder.class_eval do
      def attribute_select(options = {}, html_options = {})
        raise ArgumentError, "attribute_select must be called inside a search FormBuilder!" unless object.respond_to?(:context)
        options[:include_blank] = true unless options.has_key?(:include_blank)

        # Set default associations set on model with 'has_ransackable_associations'
        if options[:associations].nil?
          options[:associations] = object.context.klass.ransackable_associations
        end

        bases = [''] + association_array(options[:associations])
        if bases.size > 1
          @template.select(
            @object_name, :name,
            @template.grouped_options_for_select(attribute_collection_for_bases(bases, options[:attributes]), object.name),
            objectify_options(options), @default_options.merge(html_options)
          )
        else
          @template.select(
            @object_name, :name, attribute_collection_for_base(bases.first, options[:attributes]),
            objectify_options(options), @default_options.merge(html_options)
          )
        end
      end

      def sort_select(options = {}, html_options = {})
        raise ArgumentError, "sort_select must be called inside a search FormBuilder!" unless object.respond_to?(:context)
        options[:include_blank] = true unless options.has_key?(:include_blank)
        bases = [''] + association_array(options[:associations])
        if bases.size > 1
          @template.select(
            @object_name, :name,
            @template.grouped_options_for_select(attribute_collection_for_bases(bases, options[:attributes]), object.name),
            objectify_options(options), @default_options.merge({:class => 'ransack_sort'}).merge(html_options)
          ) + @template.collection_select(
            @object_name, :dir, [['asc', object.translate('asc')], ['desc', object.translate('desc')]], :first, :last,
            objectify_options(options.except(:include_blank)), @default_options.merge({:class => 'ransack_sort_order'}).merge(html_options)
          )
        else
          # searchable_attributes now returns [c, type]
          collection = object.context.searchable_attributes(bases.first).map do |c, type|
            [
              attr_from_base_and_column(bases.first, c),
              Translate.attribute(attr_from_base_and_column(bases.first, c), :context => object.context)
            ]
          end
          @template.collection_select(
            @object_name, :name, collection, :first, :last,
            objectify_options(options), @default_options.merge({:class => 'ransack_sort'}).merge(html_options)
          ) + @template.collection_select(
            @object_name, :dir, [['asc', object.translate('asc')], ['desc', object.translate('desc')]], :first, :last,
            objectify_options(options.except(:include_blank)), @default_options.merge({:class => 'ransack_sort_order'}).merge(html_options)
          )
        end
      end

      def predicate_keys(options)
        keys = options[:compounds] ? Predicate.names : Predicate.names.reject {|k| k.match(/_(any|all)$/)}
        if only = options[:only]
          if only.respond_to? :call
            keys = keys.select {|k| only.call(k)}
          else
            only = Array.wrap(only).map(&:to_s)
            # Create compounds hash, e.g. {"eq" => ["eq", "eq_any", "eq_all"], "blank" => ["blank"]}
            key_groups = keys.inject(Hash.new([])){ |h,k| h[k.sub(/_(any|all)$/, '')] += [k]; h }
            # Order compounds hash by 'only' keys
            keys = only.map {|k| key_groups[k] }.flatten.compact
          end
        end
        keys
      end

      def predicate_select(options = {}, html_options = {})
        options = Ransack.options[:default_predicates] || {} if options.blank?

        options[:compounds] = true if options[:compounds].nil?
        keys = predicate_keys(options)
        # If condition is newly built with build_condition(),
        # then replace the default predicate with the first in the ordered list
        @object.predicate_name = keys.first if @object.default?
        @template.collection_select(
          @object_name, :p, keys.map {|k| [k, Translate.predicate(k)]}, :first, :last,
          objectify_options(options), @default_options.merge(html_options)
        )
      end

      def attribute_collection_for_bases(bases, attributes=nil)
        bases.map do |base|
          if collection = attribute_collection_for_base(base, attributes)
            [
              Translate.association(base, :context => object.context),
              collection
            ]
          end
        end.compact
      end

      # Passing attributes can filter out attributes from the view, a hash is expected like
      # { :model_name => [:column_1, :column2], :model_name_2 => [:column_1] }
      def attribute_collection_for_base(base, attributes=nil)
        klass = object.context.traverse(base)


        # If the foreign key is an array (composite_primary_keys) then skip
        foreign_keys = klass.reflect_on_all_associations.select(&:belongs_to?).
                         map_to({}) { |r, h| h[r.foreign_key.to_sym] = r.class_name if !r.foreign_key.is_a?(Array) }

        ajax_options = Ransack.options[:ajax_options] || {}

        # Detect any inclusion validators to build list of options for a column
        column_select_options = klass.validators.each_with_object({}) do |v, hash|
          if v.is_a? ActiveModel::Validations::InclusionValidator
            v.attributes.each do |a|
              # Try to translate options from activerecord.attribute_options.<model>.<attribute>
              hash[a.to_s] = v.send(:delimiter).each_with_object({}) do |o, options|
                options[o] = I18n.translate("activerecord.attribute_options.#{klass.to_s.downcase}.#{a}.#{o}", :default => o)
              end
            end
          end
        end

        object.context.searchable_attributes(base).map do |c, type|

          # Don't show 'id' column for base model
          next nil if base.blank? && c == 'id'

          # If attributes are passed from the view, skip missing ones
          base_name = base.blank? ? klass.name.underscore.to_sym : base.to_sym
          next nil if (attributes && attributes[base_name] && !attributes[base_name].include?(c.to_sym))

          attribute = attr_from_base_and_column(base, c)
          attribute_label = Translate.attribute(attribute, :context => object.context)

          # Set model name as label for 'id' column on that model's table.
          if c == 'id'
            foreign_klass = object.context.traverse(base).model_name
            # Check that model can autocomplete. If not, skip this id column.
            next nil unless foreign_klass.constantize._ransack_autocompletes_through.present?
            # Try and find the attribute label at ransack.associations.subscriber.association otherwise default to the foreign klass name
            attribute_label = I18n.translate(
              base,
              :scope => "ransack.associations.#{object.context.klass.name.demodulize.downcase}",
              :default => I18n.translate(foreign_klass, :default => foreign_klass)
            )
          else
            foreign_klass = foreign_keys[c.to_sym]
          end


          # Add column type as data attribute
          html_options = {:'data-type' => type}
          # Set 'base' attribute if attribute is on base model
          html_options[:'data-root-model'] = true if base.blank?
          # Set column options if detected from inclusion validator
          if column_select_options[c]
            # Format options as an array of hashes with id and text columns, for Select2
            html_options[:'data-select-options'] = column_select_options[c].map {|id, text|
              {:id => id, :text => text}
            }.to_json
          end

          if foreign_klass && (autocomplete_source = foreign_klass.constantize._ransack_autocompletes_through rescue false)
            url = case autocomplete_source.first
                  when Class
                    controller_path = autocomplete_source.first.controller_path
                    if ajax_options[:url]
                      ajax_options[:url].sub(':controller', controller_path)
                    else
                      "/#{controller_path}.json"
                    end
                  else
                    route_name = autocomplete_source.first.to_s.gsub(/_(url|path)$/, '')
                    controller_path = Rails.application.routes.named_routes[route_name].defaults[:controller]
                    Rails.application.routes_url_helpers.send(*autocomplete_source)
                  end

            # If field is a foreign key, set up 'data-ajax-*' attributes for auto-complete
            html_options[:'data-ajax-url'] = url
            html_options[:'data-ajax-entity'] = I18n.translate(controller_path, :default => controller_path)
            html_options[:'data-ajax-type'] = ajax_options[:type] || 'GET'
            html_options[:'data-ajax-key']  = ajax_options[:key]  || 'query'
          end

          [
            attribute_label,
            attribute,
            html_options
          ]
        end.compact
      rescue UntraversableAssociationError => e
        nil
      end
    end

  end
end
