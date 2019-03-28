# Publish a new release into Rubygems.


1. Increment the version number in `puma-plugin-dogstatsd.gemspec`
2. Commit && push to Github this change with `Bump to <version>` message
3. `$ gem build puma-plugin-dogstatsd.gemspec`
4. `$ gem push puma-plugin-dogstatsd-<version>.gem` 

Done 🙂
