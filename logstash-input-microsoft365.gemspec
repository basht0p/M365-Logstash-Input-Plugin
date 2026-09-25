Gem::Specification.new do |s|
  s.name = 'logstash-input-microsoft365'
  s.version = '0.1.0'
  s.licenses = ['Apache-2.0']
  s.summary = 'Microsoft 365 REST activity and security input for Logstash'
  s.description = 'Collects Microsoft 365 activity, Entra, Defender, Identity Protection, and hunting events.'
  s.authors = ['M365 Logstash Input contributors']
  s.homepage = 'https://github.com/basht0p/M365-Logstash-Input-Plugin'
  s.metadata = { 'logstash_plugin' => 'true', 'logstash_group' => 'input' }
  jar_files = Dir['vendor/jars/*.jar']
  unless jar_files.any? { |path| File.basename(path).start_with?('msal4j-1.22.0') } &&
         jar_files.any? { |path| File.basename(path).start_with?('h2-2.3.232') }
    raise 'Pinned Java dependencies missing; run mvn -B dependency:copy-dependencies before gem build'
  end
  s.files = Dir['lib/**/*', 'data/**/*', 'vendor/jars/**/*', 'LICENSE', 'README.md']
  s.require_paths = ['lib']
  s.add_runtime_dependency 'logstash-core-plugin-api', '>= 2.1', '<= 3.0'
  s.add_development_dependency 'rspec', '~> 3.13'
end
