require 'erb'

Capistrano::Configuration.instance.load do
  namespace :db do
    namespace :mysql do
      desc <<-EOF
      |DarkRecipes| Performs a compressed database dump. \
      WARNING: This locks your tables for the duration of the mysqldump.
      Don't run it madly!
      EOF
      task :dump, :roles => :db, :only => { :primary => true } do
        prepare_from_yaml
        run "mysqldump --user=#{db_user} -p --host=#{db_host} #{db_name} | bzip2 -z9 > #{db_remote_file}" do |ch, stream, out|
        ch.send_data "#{db_pass}\n" if out =~ /^Enter password:/
          puts out
        end
      end

      desc "|DarkRecipes| Restores the database from the latest compressed dump"
      task :restore, :roles => :db, :only => { :primary => true } do
        prepare_from_yaml
        run "bzcat #{db_remote_file} | mysql --user=#{db_user} -p --host=#{db_host} #{db_name}" do |ch, stream, out|
        ch.send_data "#{db_pass}\n" if out =~ /^Enter password:/
          puts out
        end
      end

      desc "|DarkRecipes| Downloads the compressed database dump to this machine"
      task :fetch_dump, :roles => :db, :only => { :primary => true } do
        prepare_from_yaml
        download db_remote_file, db_local_file, :via => :scp
      end
    
      desc "|DarkRecipes| Create MySQL database and user for this environment using prompted values"
      task :setup, :roles => :db, :only => { :primary => true } do
        prepare_for_db_command

        sql = <<-SQL
        CREATE DATABASE #{db_name};
        GRANT ALL PRIVILEGES ON #{db_name}.* TO #{db_user}@localhost IDENTIFIED BY '#{db_pass}';
        SQL

        run "mysql --user=#{db_admin_user} -p --execute=\"#{sql}\"" do |channel, stream, data|
          if data =~ /^Enter password:/
            pass = Capistrano::CLI.password_prompt "Enter database password for '#{db_admin_user}':"
            channel.send_data "#{pass}\n" 
          end
        end
      end
      
      # Sets database variables from remote database.yaml
      def prepare_from_yaml
        set(:db_file) { "#{application}-dump.sql.bz2" }
        set(:db_remote_file) { "#{shared_path}/backup/#{db_file}" }
        set(:db_local_file)  { "tmp/#{db_file}" }
        set(:db_user) { db_config[rails_env]["username"] }
        set(:db_pass) { db_config[rails_env]["password"] }
        set(:db_host) { db_config[rails_env]["host"] }
        set(:db_name) { db_config[rails_env]["database"] }
      end
        
      def db_config
        @db_config ||= fetch_db_config
      end

      def fetch_db_config
        require 'yaml'
        file = capture "cat #{shared_path}/config/database.yml"
        db_config = YAML.load(file)
      end
    end

    def self.get_database_access_info(username = nil)
      environment      = Capistrano::CLI.ui.ask("\nPlease enter the environment (Default: #{fetch(:rails_env, 'dev')})")
      environment      = fetch(:rails_env, 'dev') if environment.empty?

      db_adapter       = Capistrano::CLI.ui.ask("Please enter database adapter (Options: mysql2, or postgresql. Default postgresql): ")
      db_adapter       = db_adapter.empty? ? 'postgresql' : db_adapter.gsub(/^mysql$/, 'mysql2')

      default_db_name = "#{fetch(:application, 'database')}_#{environment}"
      db_name          = Capistrano::CLI.ui.ask("Please enter database name (Default: #{default_db_name}) ")
      db_name = default_db_name if db_name.empty?

      default_username = username.nil? ? "postgres" : username
      db_username      = Capistrano::CLI.ui.ask("Please enter database username (Default: #{default_username})")
      db_username = default_username if db_username.empty?

      db_password      = Capistrano::CLI.password_prompt("Please enter database password: ")

      default_db_host  = roles[:db].servers.first
      default_db_host = "localhost" if default_db_host.nil?
      db_host          = Capistrano::CLI.ui.ask("Please enter database host (Default: #{default_db_host}): ")
      db_host          = db_host.empty? ? default_db_host : db_host

      default_pool = 5
      db_pool          = Capistrano::CLI.ui.ask("Please enter number of pool connections (Default: #{default_pool}): ")
      db_pool = default_pool if db_pool.empty?

      {
        environment.to_s => {
          "adapter" =>  db_adapter,
          "encoding" => "utf8",
          "pool" => db_pool,
          "database" => db_name,
          "username" => db_username,
          "password" => db_password,
          "host" => db_host.to_s
        }
      }
    end

    desc "|DarkRecipes| Create database.yml in shared path with settings for current stage and test env"
    task :create_yaml do
      run "mkdir -p #{shared_path}/config"
      if find_servers_for_task(current_task).size == 1
        db_config = get_database_access_info("#{application}_#{rails_env}_user")
        put db_config.to_yaml, "#{shared_path}/config/database.yml", :via => :scp
      else
        roles.keys.each do |role|
          db_config = get_database_access_info("#{application}_#{rails_env}_#{role}_user}")
          put db_config.to_yaml, "#{shared_path}/config/database.yml"
        end
      end
      run "ln -nfs #{shared_path}/config/database.yml #{current_path}/config/database.yml"
    end

    desc "[internal] Symlinks the database.yml file from shared folder into config folder"
    task :symlink, :except => {:no_release => true} do
      run "ln -nfs #{shared_path}/config/database.yml #{release_path}/config/database.yml"
    end
  end
    
  def prepare_for_db_command
    set :db_name, "#{application}_#{environment}"
    set(:db_admin_user) { Capistrano::CLI.ui.ask "Username with priviledged database access (to create db):" }
    set(:db_user) { Capistrano::CLI.ui.ask "Enter #{environment} database username:" }
    set(:db_pass) { Capistrano::CLI.password_prompt "Enter #{environment} database password:" }
  end
  
  desc "Populates the database with seed data"
  task :seed do
    Capistrano::CLI.ui.say "Populating the database..."
    run "cd #{current_path}; rake RAILS_ENV=#{variables[:rails_env]} db:seed"
  end
  
  after "deploy:setup" do
    db.create_yaml if Capistrano::CLI.ui.agree("Create database.yml in app's shared path? [Yn]")
  end
end
