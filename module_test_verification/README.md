# module_test_verification

Tests and verification: query tests (test_query_*.sh), common_sh (test_setup, test_cache, run_test_suite), python test helpers. References `module_app_core` for app paths.

## Layout

- **common_sh/** – test_setup.sh, test_cache.sh, run_test_suite.sh, test_*.sh
- **python/** – common_test_queries*.py, common_utils.py
- **test_query_*.sh** – Query tests (1_AVG, 1_TOP, 9, 2way_local variants)
- **test_results/**, **cache_files/** – Output dirs

## Usage

- Run query tests: `./module_test_verification/test_query_1_AVG.sh --test-env local` (or from repo root; scripts resolve REPO_ROOT)
- Verification/fetch-deployment-info.sh sources `module_test_verification/common_sh/test_cache.sh`
