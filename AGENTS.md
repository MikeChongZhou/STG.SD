# Release version policy

During local development and testing, do not change product versions or build numbers.

When uploading changes to GitHub, increment the product version only for platforms whose implementation actually changed. Keep that platform's user-facing version text, package metadata, build-script output names, and project documentation aligned. Increment its build number/code when building that platform for distribution. Leave the versions of unchanged platforms as they are.
