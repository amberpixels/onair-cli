# frozen_string_literal: true

require "tmpdir"

RSpec.describe Onair::CLI do
  it "prints the version and exits zero" do
    expect { described_class.run(["--version"]) }
      .to raise_error(SystemExit) { |error| expect(error.status).to eq(0) }
      .and output("#{Onair::VERSION}\n").to_stdout
  end

  it "fails with a friendly single-line error on an unknown command" do
    status = nil
    expect { status = described_class.run(["bogus"]) }
      .to output(/error: unknown command: bogus/).to_stderr
    expect(status).to eq(1)
  end

  it "fails with a friendly error on an unknown option" do
    status = nil
    expect { status = described_class.run(["--bogus"]) }
      .to output(/error: invalid option: --bogus/).to_stderr
    expect(status).to eq(1)
  end

  describe "init" do
    around do |example|
      saved = ENV.delete("HEROKU_APP")
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    ensure
      ENV["HEROKU_APP"] = saved if saved
    end

    it "writes .onair.yml" do
      status = nil
      expect { status = described_class.run(["init", "--app", "myapp"]) }
        .to output(/wrote \.onair\.yml/).to_stdout
      expect(status).to eq(0)
      expect(File.read(".onair.yml")).to eq("platform: heroku\napp: myapp\nbranch: main\n")
    end

    it "refuses to overwrite an existing config" do
      File.write(".onair.yml", "app: existing\n")
      status = nil
      expect { status = described_class.run(["init", "--app", "myapp"]) }
        .to output(/already exists/).to_stderr
      expect(status).to eq(1)
    end

    it "requires an app name" do
      status = nil
      expect { status = described_class.run(["init"]) }
        .to output(/pass --app NAME/).to_stderr
      expect(status).to eq(1)
    end

    it "appends a prod recipe to an existing justfile with --justfile" do
      File.write("justfile", "test:\n    rspec\n")
      expect { described_class.run(["init", "--app", "myapp", "--justfile"]) }
        .to output(/added `prod` recipe to justfile/).to_stdout
      expect(File.read("justfile")).to eq("test:\n    rspec\n\nprod:\n    @onair\n")
    end

    it "creates a justfile when none exists" do
      expect { described_class.run(["init", "--app", "myapp", "--justfile"]) }
        .to output(/added `prod` recipe/).to_stdout
      expect(File.read("justfile")).to eq("prod:\n    @onair\n")
    end
  end
end
