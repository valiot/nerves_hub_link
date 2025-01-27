import Config

config :nerves_hub_cli,
  home_dir: Path.expand("nerves-hub")

# API HTTP connection.
config :nerves_hub_user_api,
  host: "0.0.0.0",
  port: 4002

# Device HTTP connection.
config :nerves_hub_link,
  device_api_host: "0.0.0.0",
  device_api_port: 4001,
  configurator: NervesHubLink.Configurator.Default

# nerves_runtime needs to disable
# and mock out some parts.

cert =
  if File.exists?("./nerves-hub/test-cert.pem"),
    do: File.read!("./nerves-hub/test-cert.pem")

key =
  if File.exists?("./nerves-hub/test-key.pem"),
    do: File.read!("./nerves-hub/test-key.pem")

config :nerves_runtime,
  target: "host",
  kernel: [autoload_modules: false],
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       "nerves_fw_active" => "a",
       "a.nerves_fw_uuid" => "8a8b902c-d1a9-58aa-6111-04ab57c2f2a8",
       "a.nerves_fw_product" => "nerves_hub",
       "a.nerves_fw_architecture" => "x86_64",
       "a.nerves_fw_version" => "0.1.0",
       "a.nerves_fw_platform" => "x86_84",
       "a.nerves_fw_misc" => "extra comments",
       "a.nerves_fw_description" => "test firmware",
       "nerves_hub_cert" => cert,
       "nerves_hub_key" => key,
       "nerves_fw_devpath" => "/tmp/fwup_bogus_path",
       "nerves_serial_number" => "test"
     }}
