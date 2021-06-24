require "cli/parser"
require "digest/sha2"
require "github_packages"

module Homebrew
  module_function

  BOTTLE_REGEX = /^(?<name>\S+)-(?<version>[\d.]+)_?(?<revision>\d)?\.(?<os>\w+)\.bottle\.?(?<rebuild>\d+)?\.tar\.gz/

  def upload_args
    Homebrew::CLI::Parser.new do
      description <<~EOS
        Upload the named bottle to GitHub Packages.
      EOS
      named_args :bottle
    end
  end

  def upload
    args = upload_args.parse
    filename = args.named.first
    bottles_hash = assemble_fake_json(filename)

    github_releases = GitHubPackages.new(org: "homebrew")
    github_releases.upload_bottles(bottles_hash)
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

      if tag
        tags[match["os"]]["tab"] = tab
      end
    else
      $stderr.puts "Unable to parse bottle name!"
      return
    end

    rebuild = match["rebuild"] || 0
    rebuild = Integer(rebuild)

    target_filename = Bottle::Filename.new(match["name"], match["version"], match["os"], rebuild)

    bottles_hash = {
      match["name"] => {
        "formula" => {
          "name" => match["name"],
          "homepage" => "",
          "desc" => "",
          "license" => "",
          "pkg_version" => match["version"] + "_" + match["revision"],
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

    bottles_hash
  end
end

Homebrew.upload
