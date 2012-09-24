# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with this
# work for additional information regarding copyright ownership.  The ASF
# licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations under
# the License.

module Buildr
  module Generate #:nodoc:

    task 'generate' do
      script = nil
      choose do |menu|
        menu.header = "To use Buildr you need a buildfile. Do you want me to create one?"
	menu.choice("From eclipse .project files") { script = Generate.from_eclipse(Dir.pwd).join("\n") } if has_eclipse_project?
        menu.choice("From maven2 pom file") { script = Generate.from_maven2_pom('pom.xml').join("\n") } if File.exists?("pom.xml")
        menu.choice("From directory structure") { script = Generate.from_directory(Dir.pwd).join("\n") }
        menu.choice("Skip") { }
      end

      if script
        buildfile = File.expand_path(Buildr::Application::DEFAULT_BUILDFILES.first)
        File.open(buildfile, "w") { |file| file.write script }
        puts "Created #{buildfile}"
      end
    end

    class << self

      def compatibility_option(path)
        # compile.options.target = '1.5'
      end

      def get_project_natures(projectFile)
        return nil unless File.exists?(projectFile)
        File.open(projectFile) do |f|
          root = REXML::Document.new(f).root
          return nil if root == nil
          natures = root.elements.collect("natures/nature") { |n| n.text }
          return natures if natures
        end
        return nil
      end

      def get_build_property(path, propertyName)
        propertiesFile = File.join(path, 'build.properties')
        return nil unless File.exists?(propertiesFile)
        inhalt = Hash.from_java_properties(File.read(propertiesFile))
        binDef = inhalt[propertyName]
      end

      def has_eclipse_project?
        candidates = Dir.glob("**/.project")
        return false if candidates.size == 0
        candidates.find { |x| get_project_natures(x) }
        return false
      end


      HEADER = "# Generated by Buildr #{Buildr::VERSION}, change to your liking\n\n"

      def getEclipseBuildfileHeader(path, name)
        x = <<-EOF
#{"require 'buildr/scala'\n" if Dir.glob(path + "/**/*.scala").size > 0}
#{"require 'buildr/groovy'\n" if Dir.glob(path + "/**/*.groovy").size > 0}
# Version number for this release
VERSION_NUMBER = "1.0.0"
# Group identifier for your projects
GROUP = "#{name}"
COPYRIGHT = ""

# Specify Maven 2.0 remote repositories here, like this:
repositories.remote << "http://repo1.maven.org/maven2"

desc "The #{name.capitalize} project"
define "#{name}" do

  project.version = VERSION_NUMBER
  project.group = GROUP
  manifest["Implementation-Vendor"] = COPYRIGHT
            EOF
        return x
      end

      def setLayout(source=nil, output = nil)
        script = ""
        if source
          source = source.sub(/\/$/, '') # remove trailing /
          script += <<-EOF
  layout[:source, :main, :java] = "#{source}"
  layout[:source, :main, :scala] = "#{source}"
EOF
        end
        if output
          output = output.sub(/\/$/, '') # remove trailing /
          script += <<-EOF
  layout[:target, :main] = "#{output}"
  layout[:target, :main, :java] = "#{output}"
  layout[:target, :main, :scala] = "#{output}"
EOF
        end
        return script
      end

      # tries to read as much information as needed at the moment from an existing Eclipse workspace
      # Here are some links to the relevant information
      # * http://help.eclipse.org/juno/index.jsp?topic=/org.eclipse.pde.doc.user/reference/pde_feature_generating_build.htm
      # * http://wiki.eclipse.org/FAQ_What_is_the_plug-in_manifest_file_%28plugin.xml%29%3F
      # * http://help.eclipse.org/juno/index.jsp?topic=/org.eclipse.platform.doc.isv/reference/misc/bundle_manifest.html
      # * http://help.eclipse.org/juno/index.jsp?topic=/org.eclipse.platform.doc.isv/reference/misc/plugin_manifest.html
      # * http://help.eclipse.org/juno/index.jsp?topic=/org.eclipse.pde.doc.user/tasks/pde_compilation_env.htm
      def from_eclipse(path = Dir.pwd, root = true)
        # We need two passes to be able to determine the dependencies correctly
        Dir.chdir(path) do
          name = File.basename(path)
          dot_projects = []
          mf = nil # avoid reloading manifest
          if root
            @@allProjects = Hash.new
            @@topDir = File.expand_path(Dir.pwd)
            script = HEADER.split("\n")
            script << "require 'buildr/ide/eclipse'"
            header = getEclipseBuildfileHeader(path, name)
            script += header.split("\n")
            script << "  # you may see hints about which jars are missing and should resolve them correctly"
            script << "  # dependencies  << 'junit should be commented out and replace by correct ARTIFACT definition. Eg"
            script << "  # dependencies  << 'junit:junit:jar:3.8.2'"
            script << setLayout('src', 'bin') # default values for eclipse
            dot_projects = Dir.glob('**/.project').find_all { |dot_project| get_project_natures(dot_project) }
            dot_projects.sort.each { |dot_project| from_eclipse(File.dirname(dot_project), false) } if dot_projects
          else
            # Skip fragments. Buildr cannot handle it without the help of buildr4osgi
            return [""] if File.exists?('fragment.xml')
            projectName = name
            version = ""
            mfName = File.join('META-INF', 'MANIFEST.MF')
            if File.exists?(mfName)
              mf = Packaging::Java::Manifest.parse(IO.readlines(mfName).join(''))
              if mf.main['Bundle-SymbolicName']
                projectName = mf.main['Bundle-SymbolicName'].split(';')[0]
                bundleVersion = mf.main['Bundle-Version']
                version = ", :version => \"#{bundleVersion}\"" unless "1.0.0".eql?(bundleVersion)
              end
            end
            # in the first run we just want to know that we exist
            unless @@allProjects[projectName]
              @@allProjects[projectName] = Dir.pwd
              return
            end
            base_dir = ""
            unless File.join(@@topDir, projectName).eql?(File.expand_path(Dir.pwd))
              base_dir = ", :base_dir => \"#{File.expand_path(Dir.pwd).sub(@@topDir+File::SEPARATOR, '')}\""
            end
            script = [%{define "#{projectName}"#{version}#{base_dir} do}]
          end
          natures = get_project_natures('.project')
          if natures && natures.index('org.eclipse.pde.PluginNature')
            script << "  package(:jar)"
          end
          if mf && mf.main['Require-Bundle']
            mf.main['Require-Bundle'].split(',').each do
              |bundle|
              requiredName = bundle.split(';')[0]
              if @@allProjects.has_key?(requiredName)
                script << "  dependencies << projects(\"#{requiredName}\")"
              else
                script << "  # dependencies  << '#{requiredName}'"
              end
            end
          end
          script << "  compile.with dependencies # Add more classpath dependencies" if Dir.glob(File.join('src', '**', '*.java')).size > 0
          script << "  resources" if File.exist?("rsc")
          sourceProp = get_build_property('.', 'source..')
          outputProp = get_build_property('.', 'output..')
          if (sourceProp && !/src\/+/.match(sourceProp)) or (outputProp && !/bin\/+/.match(outputProp))
            setLayout(sourceProp, outputProp) # default values are overridden in this project
          end
          unless dot_projects.empty?
            script << ""
            dot_projects.sort.each do |dot_project|
              next if File.dirname(File.expand_path(dot_project)).eql?(File.expand_path(Dir.pwd))
              next unless get_project_natures(dot_project)
              script << from_eclipse(File.dirname(dot_project), false).flatten.map { |line| "  " + line } << ""
            end
          end
          script << "end\n\n"
          script.flatten
        end
      end

      def from_directory(path = Dir.pwd, root = true)
        Dir.chdir(path) do
          name = File.basename(path)
          if root
            script = HEADER.split("\n")
            header = getEclipseBuildfileHeader(path, name)
            script += header.split("\n")
          else
            script = [ %{define "#{name}" do} ]
          end
          script <<  "  compile.with # Add classpath dependencies" if File.exist?("src/main/java")
          script <<  "  resources" if File.exist?("src/main/resources")
          script <<  "  test.compile.with # Add classpath dependencies" if File.exist?("src/test/java")
          script <<  "  test.resources" if File.exist?("src/test/resources")
          if File.exist?("src/main/webapp")
            script <<  "  package(:war)"
          elsif File.exist?("src/main/java")
            script <<  "  package(:jar)"
          end
          dirs = FileList["*"].exclude("src", "target", "report").
            select { |file| File.directory?(file) && File.exist?(File.join(file, "src")) }
          unless dirs.empty?
            script << ""
            dirs.sort.each do |dir|
              script << from_directory(dir, false).flatten.map { |line| "  " + line } << ""
            end
          end
          script << "end"
          script.flatten
        end
      end

      def from_maven2_pom(path = 'pom.xml', root = true)
        pom = Buildr::POM.load(path)
        project = pom.project

        artifactId = project['artifactId'].first
        description = project['name'] || "The #{artifactId} project"
        project_name = File.basename(Dir.pwd)

        if root
          script = HEADER.split("\n")

          settings_file = ENV["M2_SETTINGS"] || File.join(ENV['HOME'], ".m2/settings.xml")
          settings = XmlSimple.xml_in(IO.read(settings_file)) if File.exists?(settings_file)

          if settings
            proxy = settings['proxies'].first['proxy'].find { |proxy|
              proxy["active"].nil? || proxy["active"].to_s =~ /true/
            } rescue nil

            if proxy
              url = %{#{proxy["protocol"].first}://#{proxy["host"].first}:#{proxy["port"].first}}
              exclude = proxy["nonProxyHosts"].to_s.gsub("|", ",") if proxy["nonProxyHosts"]
              script << "options.proxy.http = '#{url}'"
              script << "options.proxy.exclude << '#{exclude}'" if exclude
              script << ''
              # In addition, we need to use said proxies to download artifacts.
              Buildr.options.proxy.http = url
              Buildr.options.proxy.exclude << exclude if exclude
            end
          end

          repositories = project["repositories"].first["repository"].select { |repository|
            legacy = repository["layout"].to_s =~ /legacy/
            !legacy
          } rescue nil
          repositories = [{"name" => "Standard maven2 repository", "url" => "http://repo1.maven.org/maven2"}] if repositories.nil? || repositories.empty?
          repositories.each do |repository|
            name, url = repository["name"], repository["url"]
            script << "# #{name}"
            script << "repositories.remote << '#{url}'"
            # In addition we need to use said repositores to download artifacts.
            Buildr.repositories.remote << url.to_s
          end
          script << ""
        else
          script = []
        end

        script << "desc '#{description}'"
        script << "define '#{project_name}' do"

        groupId = project['groupId']
        script << "  project.group = '#{groupId}'" if groupId

        version = project['version']
        script << "  project.version = '#{version}'" if version

        #get plugins configurations
        plugins = project['build'].first['plugins'].first['plugin'] rescue {}
        if plugins
          compile_plugin = plugins.find{|pl| (pl['groupId'].nil? or pl['groupId'].first == 'org.apache.maven.plugins') and pl['artifactId'].first == 'maven-compiler-plugin'}
          if compile_plugin
            source = compile_plugin.first['configuration'].first['source'] rescue nil
            target = compile_plugin.first['configuration'].first['target'] rescue nil

            script << "  compile.options.source = '#{source}'" if source
            script << "  compile.options.target = '#{target}'" if target
          end
        end

        compile_dependencies = pom.dependencies
        dependencies = compile_dependencies.sort.map{|d| "'#{d}'"}.join(', ')
        script <<  "  compile.with #{dependencies}" unless dependencies.empty?

        test_dependencies = (pom.dependencies(['test']) - compile_dependencies).reject{|d| d =~ /^junit:junit:jar:/ }
        #check if we have testng
        use_testng = test_dependencies.find{|d| d =~ /^org.testng:testng:jar:/}
        if use_testng
          script <<  "  test.using :testng"
          test_dependencies = pom.dependencies(['test']).reject{|d| d =~ /^org.testng:testng:jar:/ }
        end

        test_dependencies = test_dependencies.sort.map{|d| "'#{d}'"}.join(', ')
        script <<  "  test.with #{test_dependencies}" unless test_dependencies.empty?

        packaging = project['packaging'] ? project['packaging'].first : 'jar'
        if %w(jar war).include?(packaging)
          script <<  "  package :#{packaging}, :id => '#{artifactId}'"
        end

        modules = project['modules'].first['module'] rescue nil
        if modules
          script << ""
          modules.each do |mod|
            script << from_maven2_pom(File.join(File.dirname(path), mod, 'pom.xml'), false).flatten.map { |line| "  " + line } << ""
          end
        end
        script << "end"
        script.flatten
      end

    end
  end
end
