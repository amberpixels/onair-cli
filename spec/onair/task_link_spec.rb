# frozen_string_literal: true

RSpec.describe Onair::TaskLink do
  describe ".from_config" do
    it "is nil when the section is absent" do
      expect(described_class.from_config(nil)).to be_nil
    end

    it "builds a matcher from pattern and url" do
      task = described_class.from_config("pattern" => 'ABC-\d+', "url" => "https://tracker.example/{task}")
      expect(task.find("ABC-1922: Add the widget")).to eq("ABC-1922")
      expect(task.url_for("ABC-1922")).to eq("https://tracker.example/ABC-1922")
    end

    it "requires both pattern and url" do
      expect { described_class.from_config("pattern" => 'ABC-\d+') }
        .to raise_error(Onair::Error, /both `pattern` and `url`/)
      expect { described_class.from_config("url" => "https://tracker.example/{task}") }
        .to raise_error(Onair::Error, /both `pattern` and `url`/)
    end

    it "requires the {task} placeholder in the url" do
      expect { described_class.from_config("pattern" => 'ABC-\d+', "url" => "https://tracker.example/") }
        .to raise_error(Onair::Error, /\{task\} placeholder/)
    end

    it "explains an invalid regex" do
      expect { described_class.from_config("pattern" => "ABC-(", "url" => "https://tracker.example/{task}") }
        .to raise_error(Onair::Error, /invalid task.pattern/)
    end
  end

  describe "#find" do
    let(:task) { described_class.from_config("pattern" => '[A-Z]+-\d+', "url" => "https://t.example/{task}") }

    it "returns the first match" do
      expect(task.find("ENG-42: fix ENG-43 fallout")).to eq("ENG-42")
    end

    it "is nil for no match or nil subject" do
      expect(task.find("plain subject")).to be_nil
      expect(task.find(nil)).to be_nil
    end
  end
end
