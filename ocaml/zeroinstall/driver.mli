(* Copyright (C) 2013, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Manages the process of downloading feeds during a solve.
    We use the solver to get the current best solution and the set of feeds it queried.
    We download any missing feeds and update any out-of-date ones, resolving each time
    we have more information. *)

(** Find the best selections for these requirements and return them if available without downloading. 
 * Returns None if we need to refresh feeds or download any implementations. *)
val quick_solve :
  < config : General.config; distro : Distro.distribution; .. > ->
  Requirements.requirements -> Solver.Qdom.element option

(** Run the solver, then download any feeds that are missing or that need to be
    updated. Each time a new feed is imported into the cache, the solver is run
    again, possibly adding new downloads.

    Note: if we find we need to download anything, we will refresh everything.

    @param watcher notify of each partial solve (used by the GUI to show the current state)
    @param force re-download all feeds, even if we're ready to run (implies update_local)
    @param update_local fetch PackageKit feeds even if we're ready to run
    
    @return whether a valid solution was found, the solution itself, and the feed
            provider used (which will have cached all the feeds used in the solve).
    *)
val solve_with_downloads :
  General.config -> Distro.distribution -> Fetch.fetcher ->
  watcher:#Progress.watcher ->
  Requirements.requirements ->
  force:bool ->
  update_local:bool ->
  (bool * Solver.result * Feed_provider.feed_provider) Lwt.t

(** Convenience wrapper for [fetcher#download_and_import_feed] that just gives the final result.
 * If the mirror replies first, but the primary succeeds, we return the primary. *)
val download_and_import_feed :
  Fetch.fetcher ->
  [ `remote_feed of General.feed_url ] ->
  [ `aborted_by_user | `no_update | `success of Support.Qdom.element ]
  Lwt.t

(** Download any missing implementations needed for a set of selections.
 * @param include_packages whether to include distribution packages
 * @param feed_provider it's more efficient to reuse the provider returned by [solve_with_downloads], if possible
 *)
val download_selections :
  General.config -> Distro.distribution -> Fetch.fetcher ->
  include_packages:bool ->
  feed_provider:Feed_provider.feed_provider ->
  Support.Qdom.element -> [ `aborted_by_user | `success ] Lwt.t
