# frozen_string_literal: true

module Noticed
  module Openwa
    # What the gem returns is Ruby's: OpenWA's JSON with its keys as snake_case symbols (`"messageId"` is `:message_id`),
    # in nested hashes and arrays too. Only keys change; values are OpenWA's.
    module Keys
      module_function

      def symbolize(value)
        case value
        when Hash then value.to_h { |key, each| [ snake_case(key), symbolize(each) ] }
        when Array then value.map { symbolize(_1) }
        else value
        end
      end

      def snake_case(key)
        key.to_s.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").downcase.to_sym
      end
    end
  end
end
