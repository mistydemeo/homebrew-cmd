require "cli/parser"
require "digest/sha2"
require "github_packages"

module Homebrew
  module_function

  class UploadBottleData
    attr_reader :name, :pkg_version, :rebuild, :bottles_hash

    def initialize(name, pkg_version, rebuild, bottles_hash)
      @name = name
      @pkg_version = pkg_version
      @rebuild = rebuild
      @bottles_hash = bottles_hash
    end
  end

  BOTTLE_REGEX = /^(?<name>\S+)-(?<version>[\d.]+)_?(?<revision>\d)?\.(?<os>\w+)\.bottle\.?(?<rebuild>\d+)?\.tar\.gz/
  ROOT_URL = "https://ghcr.io/v2/homebrew/core"

  def upload_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Upload the named bottle to GitHub Packages.
      EOS
      named_args :bottle
      switch "-n", "--dry-run",
             description: "Print what would be done rather than doing it."
    end
  end

  def fetch_bottle_data(spec)
    resource = Resource.new("#{spec.name}_bottle_manifest")

    version_rebuild = GitHubPackages.version_rebuild(spec.pkg_version, spec.rebuild)
    resource.version(version_rebuild)

    image_name = GitHubPackages.image_formula_name(spec.name)
    image_tag = GitHubPackages.image_version_rebuild(version_rebuild)
    resource.url("#{ROOT_URL}/#{image_name}/manifests/#{image_tag}", {
      using:   CurlGitHubPackagesDownloadStrategy,
      headers: ["Accept: application/vnd.oci.image.index.v1+json"],
    })
    resource.downloader.resolved_basename = "#{spec.name}-#{version_rebuild}.bottle_manifest.json"
    # We'll be rebuilding this frequently; we need to download it
    # fresh every time.
    resource.cached_download.delete if resource.cached_download.exist?

    resource.fetch(verify_download_integrity: false)
  end

  def upload
    args = upload_args.parse
    if args.no_named?
      puts "No bottle named!"
      exit 1
    end
    dry_run = args.dry_run?

    filename = args.named.first
    # Messy, sure, but it works
    if filename != File.basename(filename)
      Dir.chdir(File.dirname(filename))
      filename = File.basename(filename)
    end

    data = assemble_fake_json(filename)
    bottles_hash = data.bottles_hash

    should_skip = false
    source_exists = true
    begin
      bottle_data = JSON.parse(fetch_bottle_data(data).read)
      versions = bottle_data["manifests"].map {|manifest| manifest["annotations"]["org.opencontainers.image.ref.name"]}
      local_version = data.pkg_version + "." + bottles_hash[data.name]["bottle"]["tags"].keys.first + "." + data.rebuild.to_s

      should_skip = true if versions.include?(local_version)
    rescue DownloadError, JSON::ParserError
      should_skip = false
      source_exists = false
    end

    if should_skip
      $stderr.puts "Skipping; bottle already uploaded for this version"
      return 0
    end

    # We only keep_old if there's already metadata there.
    keep_old = source_exists

    github_releases = GitHubPackages.new(org: "homebrew")
    github_releases.upload_bottles(bottles_hash, keep_old: keep_old, dry_run: dry_run, warn_on_error: false)
  end

  def sha256(filename)
    Digest::SHA256.hexdigest(File.read(filename))
  end

  def fetch_tab(filename)
    files = `tar -tf "#{filename}" '*INSTALL_RECEIPT.json' 2>&1`.chomp.split

    return if files.empty?
    tab = files.first

    JSON.parse(`tar -xzf "#{filename}" --to-stdout "#{tab}"`)
  end

  # We can't parse this out of some old bottles. But we can figure it
  # out ourselves.
  def assemble_fake_json(filename)
    match = BOTTLE_REGEX.match(filename)
    rebuild = match["rebuild"] || 0
    rebuild = Integer(rebuild)
    target_filename = Bottle::Filename.new(match["name"], match["version"], match["os"], rebuild)

    tab = fetch_tab(filename)

    if match
      shasum = sha256(filename)
      tags = {
        match["os"] => {
          "filename" => target_filename.to_s,
          "local_filename" => filename,
          "sha256" => shasum,
        }
      }

      if tab
        tags[match["os"]]["tab"] = tab
      end
    else
      $stderr.puts "Unable to parse bottle name!"
      return
    end

    pkg_version = if match["revision"]
      match["version"] + "_" + match["revision"]
    else
      match["version"]
    end
    bottles_hash = {
      match["name"] => {
        "formula" => {
          "name" => match["name"],
          "homepage" => "",
          "desc" => "",
          "license" => "",
          "pkg_version" => pkg_version,
          "tap_git_path" => "Formula/#{match["name"]}.rb",
          "tap_git_revision" => "",
        },
        "bottle" => {
          "rebuild" => rebuild,
          "root_url" => "https://ghcr.io/v2/homebrew/core",
          "date" => Pathname(filename.to_s).mtime.strftime("%F"),
          "tags" => tags,
        }
      }
    }

    UploadBottleData.new(match["name"], pkg_version, rebuild, bottles_hash)
  end
end

Homebrew.upload
