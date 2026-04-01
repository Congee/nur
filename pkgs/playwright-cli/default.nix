{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
}:

buildNpmPackage rec {
  pname = "playwright-cli";
  version = "0.1.3";

  src = fetchFromGitHub {
    owner = "microsoft";
    repo = "playwright-cli";
    rev = "v${version}";
    hash = "sha256-ewydxWKXTZ6+NDaIH5krRcWYdLPsi8O3EEgfapasTXU=";
  };

  npmDepsHash = "sha256-MYUFGz+ZhlO6QYMQOwwEr1cJ+NvDvdkLKwZfJBvh6sI=";

  dontNpmBuild = true;

  passthru = {
    # Newer upstream tags intentionally print a deprecation message and exit.
    skipBulkUpdate = true;
  };

  meta = with lib; {
    description = "Playwright CLI for browser automation";
    homepage = "https://github.com/microsoft/playwright-cli";
    changelog = "https://github.com/microsoft/playwright-cli/releases/tag/v${version}";
    license = licenses.asl20;
    maintainers = with maintainers; [ imalison ];
    mainProgram = "playwright-cli";
  };
}
