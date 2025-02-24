require 'test_puppet_helper'

module ForemanPuppet
  module Api
    module V2
      class SmartProxiesControllerTest < ActionController::TestCase
        tests ::Api::V2::SmartProxiesController

        describe 'POST #import_puppetclasses' do
          # puppetmaster proxy - import_puppetclasses tests

          let(:proxy) { FactoryBot.create(:puppet_smart_proxy) }

          test 'should import new environments' do
            setup_import_classes
            as_admin do
              Host::Managed.update_all(environment_id: nil)
              Hostgroup.update_all(environment_id: nil)
              Puppetclass.destroy_all
              Environment.destroy_all
            end
            assert_difference('Environment.unscoped.count', 2) do
              post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
            end
            assert_response :success
            response = ActiveSupport::JSON.decode(@response.body)
            assert_equal 2, response['environments_with_new_puppetclasses']
          end

          # this is intentional: put test_attributes only for the first generated test eg: dryrun_param = {}
          test_attributes pid: '385efd1b-6146-47bf-babf-0127ce5955ed'
          [{}, { dryrun: false }, { dryrun: 'false' }].each do |dryrun_param|
            test 'should import new puppetclasses' do
              setup_import_classes
              as_admin do
                Host::Managed.update_all(environment_id: nil)
                Hostgroup.update_all(environment_id: nil)
                Puppetclass.destroy_all
                Environment.destroy_all
                assert_difference(-> { ForemanPuppet::Puppetclass.unscoped.count }, 1) do
                  post :import_puppetclasses,
                    params: { id: proxy.id }.merge(dryrun_param),
                    session: set_session_user
                end
              end
              assert_response :success
              assert_match 'Successfully updated environment and puppetclasses from the on-disk puppet installation', @response.body
            end
          end

          test 'should not import new puppetclasses when dryrun' do
            setup_import_classes
            as_admin do
              Host::Managed.update_all(environment_id: nil)
              Hostgroup.update_all(environment_id: nil)
              Puppetclass.destroy_all
              Environment.destroy_all
              assert_difference(-> { ForemanPuppet::Puppetclass.unscoped.count }, 0) do
                post :import_puppetclasses, params: { id: proxy.id, dryrun: true }, session: set_session_user
              end
            end
            assert_response :success
          end

          test 'should obsolete environment' do
            setup_import_classes
            as_admin do
              FactoryBot.create(:environment, name: 'xyz')
            end

            post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
            assert_response :success
            as_admin do
              assert_nil ForemanPuppet::Environment.find_by(name: 'xyz')
            end
          end

          test 'should obsolete puppetclasses' do
            setup_import_classes
            as_admin do
              assert_difference(-> { ForemanPuppet::Environment.unscoped.find_by(name: 'env1').puppetclasses.count }, -2) do
                post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
              end
            end
            assert_response :success
          end

          test 'should update puppetclass smart class parameters' do
            setup_import_classes
            LookupKey.destroy_all
            assert_difference(-> { LookupKey.unscoped.count }, 1) do
              post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
            end
            assert_response :success
          end

          test 'no changes on import_puppetclasses' do
            setup_import_classes
            Puppetclass.find_by(name: 'b').destroy
            Puppetclass.find_by(name: 'c').destroy
            assert_difference(-> { ForemanPuppet::Environment.unscoped.count }, 0) do
              post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
            end
            assert_response :success
            response = ActiveSupport::JSON.decode(@response.body)
            assert_equal 'Successfully updated environment and puppetclasses from the on-disk puppet installation', response['message']
          end

          test 'should import new environment that does not exist in db' do
            setup_import_classes
            as_admin do
              env_name = 'env1'
              assert Environment.find_by(name: env_name).destroy
              assert_difference('Environment.unscoped.count', 1) do
                post :import_puppetclasses, params: { id: proxy.id, environment_id: env_name }, session: set_session_user
              end
              assert_response :success
              response = ActiveSupport::JSON.decode(@response.body)
              assert_equal env_name, response['results']['name']
            end
          end

          test 'should NOT delete environment if pass ?except=obsolete' do
            setup_import_classes
            as_admin do
              Environment.create!(name: 'xyz')
            end
            assert_difference(-> { ForemanPuppet::Environment.unscoped.count }, 0) do
              post :import_puppetclasses, params: { id: proxy.id, except: 'obsolete' }, session: set_session_user
            end
            assert_response :success
          end

          test 'should NOT add or update puppetclass smart class parameters if pass ?except=new,updated' do
            setup_import_classes
            LookupKey.destroy_all
            assert_difference(-> { LookupKey.unscoped.count }, 0) do
              post :import_puppetclasses, params: { id: proxy.id, except: 'new,updated' }, session: set_session_user
            end
            assert_response :success
          end

          context 'import puppetclasses' do
            setup do
              ProxyAPI::Puppet.any_instance.stubs(:environments).returns(%w[env1 env2])
              classes_env1 = { 'a' => Foreman::ImporterPuppetclass.new('name' => 'a') }
              classes_env2 = { 'b' => Foreman::ImporterPuppetclass.new('name' => 'b') }

              ProxyAPI::Puppet.any_instance.stubs(:classes).with('invalid').returns({})
              ProxyAPI::Puppet.any_instance.stubs(:classes).with('env1').returns(classes_env1)
              ProxyAPI::Puppet.any_instance.stubs(:classes).with('env2').returns(classes_env2)
            end

            test 'should render templates according to api version 2' do
              post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
              assert_template 'foreman_puppet/api/v2/import_puppetclasses/index'
            end

            test 'should import puppetclasses for specified environment only' do
              assert_difference(-> { ForemanPuppet::Puppetclass.unscoped.count }, 1) do
                post :import_puppetclasses, params: { id: proxy.id, environment_id: 'env1' }, session: set_session_user
                assert_includes Puppetclass.pluck(:name), 'a'
                assert_not_includes Puppetclass.pluck(:name), 'b'
              end
              assert_response :success
            end

            test 'should render error message when invalid environment is set' do
              env = 'invalid'
              assert_difference(-> { ForemanPuppet::Puppetclass.unscoped.count }, 0) do
                post :import_puppetclasses, params: { id: proxy.id, environment_id: env }, session: set_session_user
                assert_not_includes Puppetclass.pluck(:name), 'a'
                assert_not_includes Puppetclass.pluck(:name), 'b'
              end
              response = ActiveSupport::JSON.decode(@response.body)
              assert_equal 'The requested environment cannot be found.', response['message']
              assert_response :success
            end

            test 'should import puppetclasses for all environments if none specified' do
              assert_difference(-> { ForemanPuppet::Puppetclass.unscoped.count }, 2) do
                post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
              end
              assert_includes Puppetclass.pluck(:name), 'a'
              assert_includes Puppetclass.pluck(:name), 'b'
              assert_response :success
            end

            context 'ignored environments or classes are set' do
              setup do
                setup_import_classes
              end

              test 'should contain ignored environments' do
                env_name = 'env1'
                PuppetClassImporter.any_instance.stubs(:ignored_environments).returns([env_name])

                as_admin do
                  post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
                  assert_response :success
                  response = ActiveSupport::JSON.decode(@response.body)
                  assert_equal env_name, response['results'][0]['ignored_environment']
                end
              end

              test 'should contain ignored puppet_classes' do
                PuppetClassImporter.any_instance.stubs(:ignored_classes).returns([/^a$/])

                as_admin do
                  post :import_puppetclasses, params: { id: proxy.id }, session: set_session_user
                  assert_response :success
                  response = ActiveSupport::JSON.decode(@response.body)
                  assert_includes response['results'][0]['ignored_puppetclasses'], 'a'
                  assert_not_includes response['results'][0]['ignored_puppetclasses'], 'c'
                end
              end
            end
          end
        end

        private

        def setup_import_classes
          as_admin do
            ::Host::Managed.update_all(environment_id: nil)
            ::Hostgroup.update_all(environment_id: nil)
            ForemanPuppet::HostClass.destroy_all
            ForemanPuppet::HostgroupClass.destroy_all
            ForemanPuppet::Puppetclass.destroy_all
            ForemanPuppet::Environment.destroy_all
          end
          orgs = [taxonomies(:organization1)]
          locs = [taxonomies(:location1)]
          # This is the database status
          # and should result in a db_tree of {"env1" => ["a", "b", "c"], "env2" => ["a", "b", "c"]}
          as_admin do
            %w[a b c].each { |name| ForemanPuppet::Puppetclass.create name: name }
            %w[env1 env2].each do |name|
              e = ForemanPuppet::Environment.create!(name: name, organizations: orgs, locations: locs)
              e.puppetclasses = ForemanPuppet::Puppetclass.all
            end
          end
          # This is the on-disk status
          # and should result in a disk_tree of {"env1" => ["a", "b", "c"],"env2" => ["a", "b", "c"]}
          envs = HashWithIndifferentAccess.new(env1: %w[a b c], env2: %w[a b c])
          pcs = [HashWithIndifferentAccess.new('a' => { 'name' => 'a', 'module' => nil, 'params' => { 'key' => 'special' } })]
          classes = pcs.map { |k| [k.keys.first, Foreman::ImporterPuppetclass.new(k.values.first)] }.to_h
          ForemanPuppet::Environment.expects(:puppetEnvs).returns(envs).at_least(0)
          ProxyAPI::Puppet.any_instance.stubs(:environments).returns(%w[env1 env2])
          ProxyAPI::Puppet.any_instance.stubs(:classes).returns(classes)
        end
      end
    end
  end
end
