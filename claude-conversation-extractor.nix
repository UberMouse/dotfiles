{ lib, python3Packages, fetchFromGitHub }:

python3Packages.buildPythonApplication rec {
  pname = "claude-conversation-extractor";
  version = "1.1.2";

  src = fetchFromGitHub {
    owner = "ZeroSumQuant";
    repo = "claude-conversation-extractor";
    rev = "refs/tags/v${version}";
    hash = "sha256-meqVJVEM7WeYZZ8BqBXg4ZW+kM2jFkt8cb9RYAN8v8I=";
  };

  propagatedBuildInputs = [
    # Core features require no external dependencies
    # Optional: add python3Packages.spacy if semantic search is needed
  ];

  nativeBuildInputs = [
    python3Packages.setuptools
  ];

  # Project uses setuptools via setup.py
  build-backend = "setuptools.build_meta";

  meta = with lib; {
    description = "Extract and search Claude API conversations";
    homepage = "https://github.com/ZeroSumQuant/claude-conversation-extractor";
    license = licenses.mit;
    maintainers = [];
  };
}
