# frozen_string_literal: true

require_relative "../../script/release_version"

RSpec.describe ReleaseVersion do
  describe ".next_rc" do
    {
      [ [], "patch" ] => "0.1.0.rc1",
      [ [], "major" ] => "0.1.0.rc1",
      [ %w[v0.1.0.rc1], "patch" ] => "0.1.0.rc2",
      [ %w[v0.1.0.rc1 v0.1.0.rc12 v0.1.0.rc2], "patch" ] => "0.1.0.rc13",
      [ %w[v0.1.0.rc2], "minor" ] => "0.2.0.rc1",
      [ %w[v0.1.0.rc2], "major" ] => "1.0.0.rc1",
      [ %w[v0.1.0.rc2 v0.2.0.rc1], "minor" ] => "0.2.0.rc2",
      [ %w[v0.1.0.rc2 v0.2.0.rc1], "patch" ] => "0.2.0.rc2",
      [ %w[v0.1.0.rc2 v0.2.0.rc1], "major" ] => "1.0.0.rc1",
      [ %w[v0.1.0.rc2 v1.0.0.rc1], "minor" ] => "1.0.0.rc2",
      [ %w[v0.1.0.rc2 v1.0.0.rc1], "major" ] => "1.0.0.rc2",
      [ %w[v0.1.0.rc12 v0.1.0], "patch" ] => "0.1.1.rc1",
      [ %w[v0.1.0.rc12 v0.1.0 v0.1.1.rc1], "patch" ] => "0.1.1.rc2",
      [ %w[v0.1.0 v0.1.1.rc3], "minor" ] => "0.2.0.rc1",
      [ %w[v0.1.0 v0.2.0.rc3], "minor" ] => "0.2.0.rc4",
      [ %w[v0.1.0 v0.2.0.rc3], "patch" ] => "0.2.0.rc4",
      [ %w[v0.1.0 v0.2.0.rc3], "major" ] => "1.0.0.rc1",
      [ %w[v0.1.0 v1.0.0.rc1], "minor" ] => "1.0.0.rc2",
      [ %w[v1.2.3], "minor" ] => "1.3.0.rc1",
      [ %w[v1.2.3], "major" ] => "2.0.0.rc1",
      [ %w[v0.1.0 other-tag v0.1.0.beta1], "patch" ] => "0.1.1.rc1"
    }.each do |(tags, bump), version|
      it "is #{version} after #{tags.inspect} with a #{bump} bump" do
        expect(described_class.next_rc(tags, bump)).to eq(version)
      end
    end

    it "ignores a closed series' candidates" do
      expect(described_class.next_rc(%w[v0.1.0.rc12 v0.1.0 v0.1.1.rc2 v0.1.1], "patch")).to eq("0.1.2.rc1")
    end

    it "refuses an unknown bump" do
      expect { described_class.next_rc([], "huge") }.to raise_error(ReleaseVersion::Error, /unknown bump/)
    end
  end

  describe ".promote" do
    it "is the candidate's version" do
      expect(described_class.promote(%w[v0.1.0.rc11 v0.1.0.rc12], "v0.1.0.rc12")).to eq("0.1.0")
    end

    it "releases a series that left an unreleased one behind" do
      expect(described_class.promote(%w[v0.1.0.rc1 v0.1.0.rc2 v1.0.0.rc1], "v1.0.0.rc1")).to eq("1.0.0")
    end

    {
      [ %w[v0.1.0.rc12], "v0.1.0" ] => /isn't a release candidate/,
      [ %w[v0.1.0.rc12 v0.1.0], "v0.1.0.rc12" ] => /already released/,
      [ %w[v0.1.0.rc10 v0.1.0.rc12], "v0.1.0.rc10" ] => /isn't the latest candidate of 0.1.0: rc12 is/,
      [ %w[v0.1.0 v0.1.1.rc1 v0.2.0], "v0.1.1.rc1" ] => /older than the last release, 0.2.0/,
      [ %w[v0.1.1.rc2 v0.2.0.rc1], "v0.1.1.rc2" ] => /0.2.0 has candidates/
    }.each do |(tags, tag), error|
      it "refuses #{tag} after #{tags.inspect}" do
        expect { described_class.promote(tags, tag) }.to raise_error(ReleaseVersion::Error, error)
      end
    end
  end

  describe ".notes_start" do
    let(:tags) { %w[v0.1.0.rc1 v0.1.0.rc2 v0.1.0 v0.1.1.rc1 v0.1.1.rc2] }

    {
      "0.1.0.rc1" => nil,
      "0.1.0.rc2" => "v0.1.0.rc1",
      "0.1.1.rc1" => "v0.1.0",
      "0.1.1.rc2" => "v0.1.1.rc1",
      "0.1.1" => "v0.1.0",
      "v0.1.0" => nil
    }.each do |version, start|
      it "is #{start.inspect} for #{version}" do
        expect(described_class.notes_start(tags, version)).to eq(start)
      end
    end
  end
end
