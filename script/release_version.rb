# frozen_string_literal: true

require "rubygems"

# The release versions, computed from the repository's tags (vX.Y.Z and vX.Y.Z.rcN); nothing is committed to bump them.
#
#   ruby script/release_version.rb next_rc [patch|minor|major]   # the version of the next release candidate
#   ruby script/release_version.rb promote vX.Y.Z.rcN             # the release a candidate becomes (fails if it can't)
#   ruby script/release_version.rb notes_start X.Y.Z[.rcN]          # the tag its release notes start from (none: empty)
#
# Each reads the tags from stdin, one per line (`git tag --list 'v*'`).
module ReleaseVersion
  class Error < StandardError; end

  BUMPS = %w[patch minor major].freeze
  RC = /\A(\d+\.\d+\.\d+)\.rc(\d+)\z/
  RELEASE = /\A\d+\.\d+\.\d+\z/
  FIRST = Gem::Version.new("0.1.0")

  module_function

  # The next candidate: the open series' next rcN, or rc1 of the version the bump makes from the last release (0.1.0
  # without one). A bump the open series already covers continues it (0.2.0.rc3 then a minor bump: 0.2.0.rc4).
  def next_rc(tags, bump = "patch")
    raise Error, "unknown bump #{bump.inspect}" unless BUMPS.include?(bump)

    versions = parse(tags)
    last_release = versions[:releases].max
    target = last_release ? bumped(last_release, bump) : FIRST
    open = versions[:rcs].keys.select { |base| last_release.nil? || base > last_release }.max

    return "#{target}.rc1" if open.nil? || target > open

    "#{open}.rc#{versions[:rcs][open].max + 1}"
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
  command, argument = ARGV
  tags = $stdin.each_line.to_a
  begin
    case command
    when "next_rc" then puts ReleaseVersion.next_rc(tags, argument || "patch")
    when "promote" then puts ReleaseVersion.promote(tags, argument)
    when "notes_start" then puts ReleaseVersion.notes_start(tags, argument)
    else abort "usage: release_version.rb next_rc [patch|minor|major] | promote vX.Y.Z.rcN | notes_start VERSION"
    end
  rescue ReleaseVersion::Error => e
    abort e.message
  end
end
