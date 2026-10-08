# List recipes
default:
    @just --list

# Install gem dependencies
setup:
    bundle install

# Run specs (pass a path to narrow: just test spec/onair/report_spec.rb)
test *args:
    bundle exec rspec {{args}}

# Run linter (check only)
lint:
    bundle exec standardrb

# Auto-fix linter warnings
fmt:
    bundle exec standardrb --fix

# Specs + lint, same as CI
check:
    bundle exec rake

# Run the CLI from source (just run --json)
run *args:
    bundle exec exe/onair {{args}}

# Install the gem locally to try the real `onair` binary
install:
    bundle exec rake install

# Regenerate the README demo image
demo:
    freeze --execute "ruby -Ilib scripts/demo.rb" -o assets/demo.svg
