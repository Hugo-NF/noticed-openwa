# frozen_string_literal: true

require "json"
require "rubygems"

# The release versions, computed from the repository's tags (vX.Y.Z and vX.Y.Z.rcN); nothing is committed to bump them.
#
#   ruby script/release_version.rb next_rc [patch|minor|major]   # the version of the next release candidate
#   ruby script/release_version.rb promote vX.Y.Z.rcN             # the release a candidate becomes (fails if it can't)
#   ruby script/release_version.rb notes_start X.Y.Z[.rcN]          # the tag its release notes start from (none: empty)
#   ruby script/release_version.rb first_notes X.Y.Z OWNER/REPO SHA # the first release's notes
#
# Each reads the tags from stdin, one per line (`git tag --list 'v*'`); first_notes reads the merged pull requests
# instead (`gh pr list --state merged --json number,title,author,url,mergeCommit`).
module ReleaseVersion
  class Error < StandardError; end

  BUMPS = %w[patch minor major].freeze
  RC = /\A(\d+\.\d+\.\d+)\.rc(\d+)\z/
  RELEASE = /\A\d+\.\d+\.\d+\z/
  FIRST = Gem::Version.new("0.1.0")

  module_function

  # The next candidate. Without an open series (a version with candidates, not released): rc1 of the version the bump
  # makes from the last release (0.1.0 for the first ever). With one, a patch bump continues it, and so does a bump it
  # already covers from the version below it, released or not (0.1.0 then 0.2.0.rc3 and a minor bump: 0.2.0.rc4);
  # otherwise the bump starts a series from it, released or not (0.1.0.rc2 and a minor bump: 0.2.0.rc1).
  def next_rc(tags, bump = "patch")
    raise Error, "unknown bump #{bump.inspect}" unless BUMPS.include?(bump)

    versions = parse(tags)
    last_release = versions[:releases].max
    series = versions[:rcs].keys.select { |base| last_release.nil? || base > last_release }
    open = series.max
    return "#{last_release ? bumped(last_release, bump) : FIRST}.rc1" unless open

    below = [ last_release, *series ].compact.select { |version| version < open }.max
    covered = bump == "patch" || (below && open >= bumped(below, bump))
    covered ? "#{open}.rc#{versions[:rcs][open].max + 1}" : "#{bumped(open, bump)}.rc1"
  end

  # The release a candidate becomes: its base version, when it's the latest candidate of the open series and that
  # version isn't released yet.
  def promote(tags, tag)
    match = tag.to_s.delete_prefix("v").match(RC) or raise Error, "#{tag} isn't a release candidate"
    base = Gem::Version.new(match[1])
    number = match[2].to_i
    versions = parse(tags)

    raise Error, "#{base} is already released" if versions[:releases].include?(base)
    if (last_release = versions[:releases].max) && base < last_release
      raise Error, "#{base} is older than the last release, #{last_release}"
    end

    latest = versions[:rcs].fetch(base, []).max
    raise Error, "#{tag} isn't the latest candidate of #{base}: rc#{latest} is" if latest && number < latest

    newer = versions[:rcs].keys.select { |other| other > base }.min
    raise Error, "#{newer} has candidates: promote its latest one" if newer

    base.to_s
  end

  # The tag a version's notes start from: for a candidate, the latest tag below it (its notes are what it adds); for a
  # release, the previous release, so its notes hold every change of its candidates. nil for the first.
  def notes_start(tags, version)
    version = Gem::Version.new(version.to_s.delete_prefix("v"))
    versions = parse(tags)
    candidates = versions[:releases].map(&:to_s)
    candidates += versions[:rcs].flat_map { |base, numbers| numbers.map { |number| "#{base}.rc#{number}" } } if version.prerelease?
    previous = candidates.map { |name| Gem::Version.new(name) }.select { |other| other < version }.max
    previous && "v#{previous}"
  end

  # The notes of the first release, which has no previous release for GitHub's to start from (they'd start from the
  # latest candidate): every pull request merged into its commit since the beginning, oldest first, listed as GitHub
  # lists them. merged?: whether a merge commit is in the released commit's history.
  def first_notes(pull_requests, version, repository, &merged)
    included = pull_requests.select { |pull| (oid = pull.dig("mergeCommit", "oid")) && merged.call(oid) }
    lines = included.sort_by { _1["number"] }.map do |pull|
      "* #{pull['title']} by @#{pull.dig('author', 'login')} in #{pull['url']}"
    end
    [ "## What's Changed", "", *lines, "", "**Full Changelog**: https://github.com/#{repository}/commits/v#{version}" ]
      .join("\n")
  end

  def parse(tags)
    tags.each_with_object({ releases: [], rcs: Hash.new { |hash, key| hash[key] = [] } }) do |tag, versions|
      name = tag.strip.delete_prefix("v")
      if (match = name.match(RC))
        versions[:rcs][Gem::Version.new(match[1])] << match[2].to_i
      elsif name.match?(RELEASE)
        versions[:releases] << Gem::Version.new(name)
      end
    end
  end

  def bumped(version, bump)
    major, minor, patch = version.segments
    case bump
    when "major" then Gem::Version.new("#{major + 1}.0.0")
    when "minor" then Gem::Version.new("#{major}.#{minor + 1}.0")
    else Gem::Version.new("#{major}.#{minor}.#{patch + 1}")
    end
  end
end

if $PROGRAM_NAME == __FILE__
  command, argument, repository, sha = ARGV
  begin
    case command
    when "next_rc" then puts ReleaseVersion.next_rc($stdin.each_line.to_a, argument || "patch")
    when "promote" then puts ReleaseVersion.promote($stdin.each_line.to_a, argument)
    when "notes_start" then puts ReleaseVersion.notes_start($stdin.each_line.to_a, argument)
    when "first_notes"
      puts(ReleaseVersion.first_notes(JSON.parse($stdin.read), argument, repository) do |oid|
        system("git", "merge-base", "--is-ancestor", oid, sha, exception: false)
      end)
    else
      abort "usage: release_version.rb next_rc [patch|minor|major] | promote vX.Y.Z.rcN | notes_start VERSION | " \
            "first_notes VERSION OWNER/REPO SHA"
    end
  rescue ReleaseVersion::Error => e
    abort e.message
  end
end
