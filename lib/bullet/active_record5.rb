module Bullet
  module SaveWithBulletSupport
    def save(*args)
      was_new_record = new_record?
      super(*args).tap do |result|
        Bullet::Detector::NPlusOneQuery.add_impossible_object(self) if result && was_new_record
      end
    end

    def save!(*args)
      was_new_record = new_record?
      super(*args).tap do |result|
        Bullet::Detector::NPlusOneQuery.add_impossible_object(self) if result && was_new_record
      end
    end
  end

  module ActiveRecord
    def self.enable
      require 'active_record'
      ::ActiveRecord::Base.class_eval do
        class <<self
          alias_method :origin_find_by_sql, :find_by_sql
          def find_by_sql(sql, binds = [], preparable: nil, &block)
            result = origin_find_by_sql(sql, binds, preparable: nil, &block)
            if Bullet.start?
              if result.is_a? Array
                if result.size > 1
                  Bullet::Detector::NPlusOneQuery.add_possible_objects(result)
                  Bullet::Detector::CounterCache.add_possible_objects(result)
                elsif result.size == 1
                  Bullet::Detector::NPlusOneQuery.add_impossible_object(result.first)
                  Bullet::Detector::CounterCache.add_impossible_object(result.first)
                end
              elsif result.is_a? ::ActiveRecord::Base
                Bullet::Detector::NPlusOneQuery.add_impossible_object(result)
                Bullet::Detector::CounterCache.add_impossible_object(result)
              end
            end
            result
          end
        end
      end

      ::ActiveRecord::Base.prepend(SaveWithBulletSupport)

      ::ActiveRecord::Relation.class_eval do
        alias_method :origin_records, :records
        # if select a collection of objects, then these objects have possible to cause N+1 query.
        # if select only one object, then the only one object has impossible to cause N+1 query.
        def records
          result = origin_records
          if Bullet.start?
            if result.first.class.name !~ /^HABTM_/
              if result.size > 1
                Bullet::Detector::NPlusOneQuery.add_possible_objects(result)
                Bullet::Detector::CounterCache.add_possible_objects(result)
              elsif result.size == 1
                Bullet::Detector::NPlusOneQuery.add_impossible_object(result.first)
                Bullet::Detector::CounterCache.add_impossible_object(result.first)
              end
            end
          end
          result
        end
      end

      ::ActiveRecord::Associations::Preloader.class_eval do
        alias_method :origin_preloaders_for_one, :preloaders_for_one

        def preloaders_for_one(association, records, scope)
          if Bullet.start?
            records.compact!
            if records.first.class.name !~ /^HABTM_/
              records.each do |record|
                Bullet::Detector::Association.add_object_associations(record, association)
              end
              Bullet::Detector::UnusedEagerLoading.add_eager_loadings(records, association)
            end
          end
          origin_preloaders_for_one(association, records, scope)
        end
      end

      ::ActiveRecord::FinderMethods.class_eval do
        # add includes in scope
        alias_method :origin_find_with_associations, :find_with_associations
        def find_with_associations
          return origin_find_with_associations { |r| yield r } if block_given?
          records = origin_find_with_associations
          if Bullet.start?
            associations = (eager_load_values + includes_values).uniq
            records.each do |record|
              Bullet::Detector::Association.add_object_associations(record, associations)
            end
            Bullet::Detector::UnusedEagerLoading.add_eager_loadings(records, associations)
          end
          records
        end
      end

      ::ActiveRecord::Associations::JoinDependency.class_eval do
        alias_method :origin_instantiate, :instantiate
        alias_method :origin_construct, :construct
        alias_method :origin_construct_model, :construct_model

        def instantiate(result_set, aliases)
          @bullet_eager_loadings = {}
          records = origin_instantiate(result_set, aliases)

          if Bullet.start?
            @bullet_eager_loadings.each do |klazz, eager_loadings_hash|
              objects = eager_loadings_hash.keys
              Bullet::Detector::UnusedEagerLoading.add_eager_loadings(objects, eager_loadings_hash[objects.first].to_a)
            end
          end
          records
        end

        def construct(ar_parent, parent, row, rs, seen, model_cache, aliases)
          if Bullet.start?
            unless ar_parent.nil?
              parent.children.each do |node|
                key = aliases.column_alias(node, node.primary_key)
                id = row[key]
                if id.nil?
                  associations = node.reflection.name
                  Bullet::Detector::Association.add_object_associations(ar_parent, associations)
                  Bullet::Detector::NPlusOneQuery.call_association(ar_parent, associations)
                  @bullet_eager_loadings[ar_parent.class] ||= {}
                  @bullet_eager_loadings[ar_parent.class][ar_parent] ||= Set.new
                  @bullet_eager_loadings[ar_parent.class][ar_parent] << associations
                end
              end
            end
          end

          origin_construct(ar_parent, parent, row, rs, seen, model_cache, aliases)
        end

        # call join associations
        def construct_model(record, node, row, model_cache, id, aliases)
          result = origin_construct_model(record, node, row, model_cache, id, aliases)

          if Bullet.start?
            associations = node.reflection.name
            Bullet::Detector::Association.add_object_associations(record, associations)
            Bullet::Detector::NPlusOneQuery.call_association(record, associations)
            @bullet_eager_loadings[record.class] ||= {}
            @bullet_eager_loadings[record.class][record] ||= Set.new
            @bullet_eager_loadings[record.class][record] << associations
          end

          result
        end
      end

      ::ActiveRecord::Associations::CollectionAssociation.class_eval do
        # call one to many associations
        alias_method :origin_load_target, :load_target
        def load_target
          records = origin_load_target

          if Bullet.start?
            if self.is_a? ::ActiveRecord::Associations::ThroughAssociation
              Bullet::Detector::NPlusOneQuery.call_association(owner, through_reflection.name)
              association = self.owner.association self.through_reflection.name
              Array(association.target).each do |through_record|
                Bullet::Detector::NPlusOneQuery.call_association(through_record, source_reflection.name)
              end
            end
            Bullet::Detector::NPlusOneQuery.call_association(owner, reflection.name) unless @inversed
            if records.first.class.name !~ /^HABTM_/
              if records.size > 1
                Bullet::Detector::NPlusOneQuery.add_possible_objects(records)
                Bullet::Detector::CounterCache.add_possible_objects(records)
              elsif records.size == 1
                Bullet::Detector::NPlusOneQuery.add_impossible_object(records.first)
                Bullet::Detector::CounterCache.add_impossible_object(records.first)
              end
            end
          end
          records
        end

        alias_method :origin_empty?, :empty?
        def empty?
          if Bullet.start? && !reflection.has_cached_counter?
            Bullet::Detector::NPlusOneQuery.call_association(owner, reflection.name)
          end
          origin_empty?
        end

        alias_method :origin_include?, :include?
        def include?(object)
          if Bullet.start?
            Bullet::Detector::NPlusOneQuery.call_association(owner, reflection.name)
          end
          origin_include?(object)
        end
      end

      ::ActiveRecord::Associations::SingularAssociation.class_eval do
        # call has_one and belongs_to associations
        alias_method :origin_reader, :reader
        def reader(force_reload = false)
          result = origin_reader(force_reload)
          if Bullet.start?
            if owner.class.name !~ /^HABTM_/ && !@inversed
              Bullet::Detector::NPlusOneQuery.call_association(owner, reflection.name)
              if Bullet::Detector::NPlusOneQuery.impossible?(owner)
                Bullet::Detector::NPlusOneQuery.add_impossible_object(result) if result
              else
                Bullet::Detector::NPlusOneQuery.add_possible_objects(result) if result
              end
            end
          end
          result
        end
      end

      ::ActiveRecord::Associations::HasManyAssociation.class_eval do
        alias_method :origin_many_empty?, :empty?
        def empty?
          result = origin_many_empty?
          if Bullet.start? && !reflection.has_cached_counter?
            Bullet::Detector::NPlusOneQuery.call_association(owner, reflection.name)
          end
          result
        end

        alias_method :origin_count_records, :count_records
        def count_records
          result = reflection.has_cached_counter?
          if Bullet.start? && !result && !self.is_a?(::ActiveRecord::Associations::ThroughAssociation)
            Bullet::Detector::CounterCache.add_counter_cache(owner, reflection.name)
          end
          origin_count_records
        end
      end
    end
  end
end
