/// cloak: a command-line wallet for the TSL1_SP shielded pool.
///
/// The package is a host, not a library: it wires libspiffy's transparent
/// side to libcloak's shielded side and adds a config file, a data directory
/// and the commands a person types. It is exported whole so the suite can run
/// every command in-process against a fake pool.
library;

export 'src/chain/spiffy_chain.dart' show SpiffyChain;
export 'src/chain/spiffy_header_source.dart' show SpiffyHeaderSource;
export 'src/net/ricochet_wallet_transport.dart' show RicochetWalletTransport, BoundedFrames, FrameTooLong, PoolMailbox;
export 'src/net/rounds.dart' show Rounds, MinedRoundBytes, ReadRound;
export 'src/net/deadline_transport.dart' show DeadlineTransport;
export 'src/net/timed_transport.dart' show TimedTransport;
export 'src/native/library_file.dart' show LibraryFile;
export 'src/native/native_libraries.dart' show NativeLibraries;
export 'src/process_ports.dart' show ProcessPorts;
export 'src/shell/bounded_file.dart' show BoundedFile, MessageKind;
export 'src/shell/cli.dart' show runCloak, Exit, printRefusal;
export 'src/shell/report.dart' show Report;
export 'src/shell/world.dart';
export 'src/version.dart' show CloakVersion;
export 'src/wallet/config.dart' show CloakConfig, CloakNetwork;
export 'src/wallet/sealed_store.dart' show SealedStore;
export 'src/wallet/state_file.dart' show CloakState, PaymentRecord, DepositRecord, TransparentRecord;
export 'src/wallet/wallet_dir.dart' show WalletDir, DirSource;
export 'src/wallet/wallet_lock.dart' show WalletLock;
