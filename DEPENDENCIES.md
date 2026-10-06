# Vendored dependencies

All dependencies are committed as ordinary source files, with their original
licenses. No git submodules, package manager or network access are needed to build.

| Dependency | Pinned release | Included subset | License |
| --- | --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.2.0) | v5.2.0 | SafeERC20, ReentrancyGuard, IERC20, IERC1363 and their interface imports | MIT (`lib/openzeppelin-contracts/LICENSE`) |
| [forge-std](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | v1.9.7 | `src/` for tests and the supplied protected harness | MIT / Apache-2.0 (`lib/forge-std/LICENSE-*`) |

Sources were extracted from the corresponding GitHub release-tag archives without
code changes. Unused distribution tests, scripts and configuration are omitted.
Only `AssetReceiver` is an application deployment. Mocks, handlers and factories
under `test/` are test infrastructure.
