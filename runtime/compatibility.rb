# frozen_string_literal: true
require_relative "merge_verifier"

module SharedCI
  # Preserves the historical consumer class without importing its policy into core.
  def self.merge_wrapper(config:, error_class: StandardError)
    klass = Class.new do
      define_method(:initialize) do |**options|
        @core = SharedCI::MergeVerifier.new(config: config, **options)
      rescue SharedCI::MergeVerifier::Error => error
        raise self.class::Error, error.message
      end
      define_method(:call) do
        @core.call
      rescue SharedCI::MergeVerifier::Error => error
        raise self.class::Error, error.message
      end
    end
    klass.const_set(:Error, Class.new(error_class))
    klass.const_set(:REQUIRED, config.fetch(:required_checks))
    { REPOSITORY: :repository, BRANCHES: :branches, WORKFLOW: :workflow }.each { |key, value| klass.const_set(key, config.fetch(value)) }
    klass.const_set(:SHA_PATTERN, MergeVerifier::SHA_PATTERN)
    klass.const_set(:PER_PAGE, MergeVerifier::PER_PAGE)
    klass.const_set(:MAX_PAGES, MergeVerifier::MAX_PAGES)
    %i[Api Git].each do |name|
      parent = MergeVerifier.const_get(name)
      wrapper_error = klass::Error
      child = Class.new(parent) do
        define_method(:initialize) do |*args, **options|
          super(*args, **options)
        rescue SharedCI::MergeVerifier::Error => error
          raise wrapper_error, error.message
        end
      end
      method = name == :Api ? :get : :call
      child.define_method(method) do |*args|
        super(*args)
      rescue SharedCI::MergeVerifier::Error => error
        raise wrapper_error, error.message
      end
      klass.const_set(name, child)
    end
    klass.define_singleton_method(:write_output) do |path, **values|
      MergeVerifier.write_output(path, **values)
    rescue MergeVerifier::Error => error
      raise self::Error, error.message
    end
    klass
  end
end
