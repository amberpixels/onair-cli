# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Onair::Config do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  def write_config(dir: @dir, **values)
    defaults = { "platform" => "heroku", "app" => "file-app", "repo" => "file/repo", "branch" => "develop" }
    File.write(File.join(dir, ".onair.yml"), defaults.merge(values).to_yaml)
  end

  it "reads everything from .onair.yml" do
    write_config
    config = described_class.resolve({}, env: {}, dir: @dir)
    expect(config.platform).to eq("heroku")
    expect(config.app).to eq("file-app")
    expect(config.repo).to eq("file/repo")
    expect(config.branch).to eq("develop")
    expect(config.fetch).to be(true)
  end

  it "prefers CLI flags over env vars over the file" do
    write_config
    env = { "HEROKU_APP" => "env-app" }
    expect(described_class.resolve({ app: "flag-app" }, env: env, dir: @dir).app).to eq("flag-app")
    expect(described_class.resolve({}, env: env, dir: @dir).app).to eq("env-app")
    expect(described_class.resolve({}, env: {}, dir: @dir).app).to eq("file-app")
  end

  it "keeps the GITHUB_REPO env override" do
    write_config
    config = described_class.resolve({}, env: { "GITHUB_REPO" => "env/repo" }, dir: @dir)
    expect(config.repo).to eq("env/repo")
  end

  it "searches upward from the working directory" do
    write_config
    nested = File.join(@dir, "a", "b")
    FileUtils.mkdir_p(nested)
    expect(described_class.resolve({}, env: {}, dir: nested).app).to eq("file-app")
  end

  it "stops searching at the git root" do
    write_config
    repo = File.join(@dir, "repo")
    nested = File.join(repo, "sub")
    FileUtils.mkdir_p(File.join(repo, ".git"))
    FileUtils.mkdir_p(nested)
    expect { described_class.resolve({}, env: {}, dir: nested) }
      .to raise_error(Onair::Error, /onair init/)
  end

  it "defaults platform to heroku and branch to main" do
    config = described_class.resolve({ app: "x" }, env: {}, dir: @dir)
    expect(config.platform).to eq("heroku")
    expect(config.branch).to eq("main")
  end

  it "honors --no-fetch" do
    config = described_class.resolve({ app: "x", no_fetch: true }, env: {}, dir: @dir)
    expect(config.fetch).to be(false)
  end

  it "errors with an actionable hint when no app is configured" do
    expect { described_class.resolve({}, env: {}, dir: @dir) }
      .to raise_error(Onair::Error, /--app NAME, set HEROKU_APP, or run `onair init`/)
  end

  describe "task section" do
    it "builds a TaskLink from the file" do
      write_config("task" => { "pattern" => 'ABC-\d+', "url" => "https://tracker.example/{task}" })
      config = described_class.resolve({}, env: {}, dir: @dir)
      expect(config.task.find("ABC-7: thing")).to eq("ABC-7")
    end

    it "is nil when not configured" do
      write_config
      expect(described_class.resolve({}, env: {}, dir: @dir).task).to be_nil
    end

    it "surfaces task config mistakes as friendly errors" do
      write_config("task" => { "pattern" => 'ABC-\d+' })
      expect { described_class.resolve({}, env: {}, dir: @dir) }
        .to raise_error(Onair::Error, /both `pattern` and `url`/)
    end
  end
end
