(* virt-v2v
 * Copyright (C) 2009-2014 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

(* Convert various RPM-based Linux enterprise distros.  This module
 * handles:
 *
 * - RHEL and derivatives like CentOS and ScientificLinux
 * - SUSE
 * - OpenSUSE and Fedora (not enterprisey, but similar enough to RHEL/SUSE)
 *)

open Printf

open Common_gettext.Gettext
open Common_utils

open Utils
open Types

module G = Guestfs

(* Kernel information. *)
type kernel_info = {
  ki_app : G.application2;         (* The RPM package data. *)
  ki_name : string;                (* eg. "kernel-PAE" *)
  ki_version : string;             (* version-release *)
  ki_arch : string;                (* Kernel architecture. *)
  ki_vmlinuz : string;             (* The path of the vmlinuz file. *)
  ki_vmlinuz_stat : G.stat;        (* stat(2) of vmlinuz *)
  ki_initrd : string option;       (* Path of initramfs, if found. *)
  ki_modpath : string;             (* The module path. *)
  ki_modules : string list;        (* The list of module names. *)
  ki_supports_virtio : bool;       (* Kernel has virtio drivers? *)
  ki_is_xen_kernel : bool;         (* Is a Xen paravirt kernel? *)
}

let string_of_kernel_info ki =
  sprintf "(%s, %s, %s, %s, %s, virtio=%b, xen=%b)"
    ki.ki_name ki.ki_version ki.ki_arch ki.ki_vmlinuz
    (match ki.ki_initrd with None -> "None" | Some f -> f)
    ki.ki_supports_virtio ki.ki_is_xen_kernel

(* The conversion function. *)
let rec convert ?(keep_serial_console = true) verbose (g : G.guestfs)
    ({ i_root = root; i_apps = apps; i_apps_map = apps_map }
        as inspect) source =
  (*----------------------------------------------------------------------*)
  (* Inspect the guest first.  We already did some basic inspection in
   * the common v2v.ml code, but that has to deal with generic guests
   * (anything common to Linux and Windows).  Here we do more detailed
   * inspection which can make the assumption that we are dealing with
   * an Enterprise Linux guest using RPM.
   *)

  (* We use Augeas for inspection and conversion, so initialize it early. *)
  Lib_linux.augeas_init verbose g;

  (* Basic inspection data available as local variables. *)
  let typ = g#inspect_get_type root in
  assert (typ = "linux");

  let distro = g#inspect_get_distro root in
  let family =
    match distro with
    | "rhel" | "centos" | "scientificlinux" | "redhat-based" -> `RHEL_family
    | "sles" | "suse-based" | "opensuse" -> `SUSE_family
    | _ -> assert false in

(*
  let arch = g#inspect_get_arch root in
*)
  let major_version = g#inspect_get_major_version root
(*
  and minor_version = g#inspect_get_minor_version root
*)
  and package_format = g#inspect_get_package_format root
  and package_management = g#inspect_get_package_management root in

  assert (package_format = "rpm");

  (* What grub is installed? *)
  let grub_config, grub =
    try
      List.find (
        fun (grub_config, _) -> g#is_file ~followsymlinks:true grub_config
      ) [
        "/boot/grub2/grub.cfg", `Grub2;
        "/boot/grub/menu.lst", `Grub1;
        "/boot/grub/grub.conf", `Grub1;
      ]
    with
      Not_found ->
        error (f_"no grub1/grub-legacy or grub2 configuration file was found") in

  (* Grub prefix?  Usually "/boot". *)
  let grub_prefix =
    match grub with
    | `Grub2 -> ""
    | `Grub1 ->
      let mounts = g#inspect_get_mountpoints root in
      try
        List.find (
          fun path -> List.mem_assoc path mounts
        ) [ "/boot/grub"; "/boot" ]
      with Not_found -> "" in

  (* EFI? *)
  let efi =
    if Array.length (g#glob_expand "/boot/efi/EFI/*/grub.cfg") < 1 then
      None
    else (
      (* Check the first partition of each device looking for an EFI
       * boot partition. We can't be sure which device is the boot
       * device, so we just check them all.
       *)
      let devs = g#list_devices () in
      let devs = Array.to_list devs in
      try
        Some (
          List.find (
            fun dev ->
              try
                g#part_get_gpt_type dev 1
                = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
              with G.Error _ -> false
          ) devs
        )
      with Not_found -> None
    ) in

  (* What kernel/kernel-like packages are installed on the current guest? *)
  let installed_kernels : kernel_info list =
    let rex_ko = Str.regexp ".*\\.k?o\\(\\.xz\\)?$" in
    let rex_ko_extract = Str.regexp ".*/\\([^/]+\\)\\.k?o\\(\\.xz\\)?$" in
    let rex_initrd = Str.regexp "^initr\\(d\\|amfs\\)-.*\\.img$" in
    filter_map (
      function
      | { G.app2_name = name } as app
          when name = "kernel" || string_prefix name "kernel-" ->
        (try
           (* For each kernel, list the files directly owned by the kernel. *)
           let files = Lib_linux.file_list_of_package verbose g inspect name in

           (* Which of these is the kernel itself? *)
           let vmlinuz = List.find (
             fun filename -> string_prefix filename "/boot/vmlinuz-"
           ) files in
           (* Which of these is the modpath? *)
           let modpath = List.find (
             fun filename ->
               String.length filename >= 14 &&
                 string_prefix filename "/lib/modules/"
           ) files in

           (* Check vmlinuz & modpath exist. *)
           if not (g#is_dir ~followsymlinks:true modpath) then
             raise Not_found;
           let vmlinuz_stat =
             try g#stat vmlinuz with G.Error _ -> raise Not_found in

           (* Get/construct the version.  XXX Read this from kernel file. *)
           let version =
             sprintf "%s-%s" app.G.app2_version app.G.app2_release in

           (* Find the initramfs which corresponds to the kernel.
            * Since the initramfs is built at runtime, and doesn't have
            * to be covered by the RPM file list, this is basically
            * guesswork.
            *)
           let initrd =
             let files = g#ls "/boot" in
             let files = Array.to_list files in
             let files =
               List.filter (fun n -> Str.string_match rex_initrd n 0) files in
             let files =
               List.filter (
                 fun n ->
                   string_find n app.G.app2_version >= 0 &&
                   string_find n app.G.app2_release >= 0
               ) files in
             match files with
             | [] ->
               warning ~prog (f_"no initrd was found in /boot matching %s %s.")
                 name version;
               None
             | [x] -> Some ("/boot/" ^ x)
             | _ ->
               error (f_"multiple files in /boot could be the initramfs matching %s %s.  This could be a bug in virt-v2v.")
                 name version in

           (* Get all modules, which might include custom-installed
            * modules that don't appear in 'files' list above.
            *)
           let modules = g#find modpath in
           let modules = Array.to_list modules in
           let modules =
             List.filter (fun m -> Str.string_match rex_ko m 0) modules in
           assert (List.length modules > 0);

           (* Determine the kernel architecture by looking at the
            * architecture of an arbitrary kernel module.
            *)
           let arch =
             let any_module = modpath ^ List.hd modules in
             g#file_architecture any_module in

           (* Just return the module names, without path or extension. *)
           let modules = filter_map (
             fun m ->
               if Str.string_match rex_ko_extract m 0 then
                 Some (Str.matched_group 1 m)
               else
                 None
           ) modules in
           assert (List.length modules > 0);

           let supports_virtio = List.mem "virtio_net" modules in
           let is_xen_kernel = List.mem "xennet" modules in

           Some {
             ki_app  = app;
             ki_name = name;
             ki_version = version;
             ki_arch = arch;
             ki_vmlinuz = vmlinuz;
             ki_vmlinuz_stat = vmlinuz_stat;
             ki_initrd = initrd;
             ki_modpath = modpath;
             ki_modules = modules;
             ki_supports_virtio = supports_virtio;
             ki_is_xen_kernel = is_xen_kernel;
           }

         with Not_found -> None
        )

      | _ -> None
    ) apps in

  if verbose then (
    printf "installed kernel packages in this guest:\n";
    List.iter (
      fun kernel -> printf "\t%s\n" (string_of_kernel_info kernel)
    ) installed_kernels;
    flush stdout
  );

  if installed_kernels = [] then
    error (f_"no installed kernel packages were found.\n\nThis probably indicates that %s was unable to inspect this guest properly.")
      prog;

  (* Now the difficult bit.  Get the grub kernels.  The first in this
   * list is the default booting kernel.
   *)
  let grub_kernels : kernel_info list =
    (* Helper function for SUSE: remove (hdX,X) prefix from a path. *)
    let remove_hd_prefix  =
      let rex = Str.regexp "^(hd.*)\\(.*\\)" in
      Str.replace_first rex "\\1"
    in

    let vmlinuzes =
      match grub with
      | `Grub1 ->
        let paths =
          let expr = sprintf "/files%s/title/kernel" grub_config in
          let paths = g#aug_match expr in
          let paths = Array.to_list paths in

          (* Remove duplicates. *)
          let paths = remove_duplicates paths in

          (* Get the default kernel from grub if it's set. *)
          let default =
            let expr = sprintf "/files%s/default" grub_config in
            try
              let idx = g#aug_get expr in
              let idx = int_of_string idx in
              (* Grub indices are zero-based, augeas is 1-based. *)
              let expr =
                sprintf "/files%s/title[%d]/kernel" grub_config (idx+1) in
              Some expr
            with Not_found -> None in

          (* If a default kernel was set, put it at the beginning of the paths
           * list.  If not set, assume the first kernel always boots (?)
           *)
          match default with
          | None -> paths
          | Some p -> p :: List.filter ((<>) p) paths in

        (* Resolve the Augeas paths to kernel filenames. *)
        let vmlinuzes = List.map g#aug_get paths in

        (* Make sure kernel does not begin with (hdX,X). *)
        let vmlinuzes = List.map remove_hd_prefix vmlinuzes in

        (* Prepend grub filesystem. *)
        List.map ((^) grub_prefix) vmlinuzes

      | `Grub2 ->
        let get_default_image () =
          let cmd =
            if g#exists "/sbin/grubby" then
              [| "grubby"; "--default-kernel" |]
            else
              [| "/usr/bin/perl"; "-MBootloader::Tools"; "-e"; "
                    InitLibrary();
                    my $default = Bootloader::Tools::GetDefaultSection();
                    print $default->{image};
                 " |] in
          match g#command cmd with
          | "" -> None
          | k ->
            let len = String.length k in
            let k =
              if len > 0 && k.[len-1] = '\n' then
                String.sub k 0 (len-1)
              else k in
            Some (remove_hd_prefix k)
        in

        let vmlinuzes =
          (match get_default_image () with
          | None -> []
          | Some k -> [k]) @
            (* This is how the grub2 config generator enumerates kernels. *)
            Array.to_list (g#glob_expand "/boot/kernel-*") @
            Array.to_list (g#glob_expand "/boot/vmlinuz-*") @
            Array.to_list (g#glob_expand "/vmlinuz-*") in
        let rex = Str.regexp ".*\\.\\(dpkg-.*|rpmsave|rpmnew\\)$" in
        let vmlinuzes = List.filter (
          fun file -> not (Str.string_match rex file 0)
        ) vmlinuzes in
        vmlinuzes in

    (* Map these to installed kernels. *)
    filter_map (
      fun vmlinuz ->
        try
          let statbuf = g#stat vmlinuz in
          let kernel =
            List.find (
              fun { ki_vmlinuz_stat = s } ->
                statbuf.G.dev = s.G.dev && statbuf.G.ino = s.G.ino
            ) installed_kernels in
          Some kernel
        with Not_found -> None
    ) vmlinuzes in

  if verbose then (
    printf "grub kernels in this guest (first in list is default):\n";
    List.iter (
      fun kernel -> printf "\t%s\n" (string_of_kernel_info kernel)
    ) grub_kernels;
    flush stdout
  );

  if grub_kernels = [] then
    error (f_"no kernels were found in the grub configuration.\n\nThis probably indicates that %s was unable to parse the grub configuration of this guest.")
      prog;

  (*----------------------------------------------------------------------*)
  (* Conversion step. *)

  let rec augeas_grub_configuration () =
    match grub with
    | `Grub1 ->
      (* Ensure Augeas is reading the grub configuration file, and if not
       * then add it.
       *)
      let incls = g#aug_match "/augeas/load/Grub/incl" in
      let incls = Array.to_list incls in
      let incls_contains_conf =
        List.exists (fun incl -> g#aug_get incl = grub_config) incls in
      if not incls_contains_conf then (
        g#aug_set "/augeas/load/Grub/incl[last()+1]" grub_config;
        Lib_linux.augeas_reload verbose g;
      )

    | `Grub2 -> () (* Not necessary for grub2. *)

  and clean_rpmdb () =
    (* Clean RPM database. *)
    assert (package_format = "rpm");
    let dbfiles = g#glob_expand "/var/lib/rpm/__db.00?" in
    let dbfiles = Array.to_list dbfiles in
    List.iter g#rm_f dbfiles

  and autorelabel () =
    (* Only do autorelabel if load_policy binary exists.  Actually
     * loading the policy is problematic.
     *)
    if g#is_file ~followsymlinks:true "/usr/sbin/load_policy" then
      g#touch "/.autorelabel";

  and unconfigure_xen () =
    (* Remove kmod-xenpv-* (RHEL 3). *)
    let xenmods =
      filter_map (
        fun { G.app2_name = name } ->
          if name = "kmod-xenpv" || string_prefix name "kmod-xenpv-" then
            Some name
          else
            None
      ) apps in
    Lib_linux.remove verbose g inspect xenmods;

    (* Undo related nastiness if kmod-xenpv was installed. *)
    if xenmods <> [] then (
      (* kmod-xenpv modules may have been manually copied to other kernels.
       * Hunt them down and destroy them.
       *)
      let dirs = g#find "/lib/modules" in
      let dirs = Array.to_list dirs in
      let dirs = List.filter (fun s -> string_find s "/xenpv" >= 0) dirs in
      let dirs = List.map ((^) "/lib/modules/") dirs in
      let dirs = List.filter g#is_dir dirs in

      (* Check it's not owned by an installed application. *)
      let dirs = List.filter (
        fun d -> not (Lib_linux.is_file_owned verbose g inspect d)
      ) dirs in

      (* Remove any unowned xenpv directories. *)
      List.iter g#rm_rf dirs;

      (* rc.local may contain an insmod or modprobe of the xen-vbd driver,
       * added by an installation script.
       *)
      (try
         let lines = g#read_lines "/etc/rc.local" in
         let lines = Array.to_list lines in
         let rex = Str.regexp ".*\\b\\(insmod|modprobe\\)\b.*\\bxen-vbd.*" in
         let lines = List.map (
           fun s ->
             if Str.string_match rex s 0 then
               "#" ^ s
             else
               s
         ) lines in
         let file = String.concat "\n" lines ^ "\n" in
         g#write "/etc/rc.local" file
       with
         G.Error msg -> eprintf "%s: /etc/rc.local: %s (ignored)\n" prog msg
      );
    );

    if family = `SUSE_family then (
      (* Remove xen modules from INITRD_MODULES and DOMU_INITRD_MODULES. *)
      let variables = ["INITRD_MODULES"; "DOMU_INITRD_MODULES"] in
      let xen_modules = ["xennet"; "xen-vnif"; "xenblk"; "xen-vbd"] in
      let modified = ref false in
      List.iter (
        fun var ->
          List.iter (
            fun xen_mod ->
              let expr =
                sprintf "/file/etc/sysconfig/kernel/%s/value[. = '%s']"
                  var xen_mod in
              let entries = g#aug_match expr in
              let entries = Array.to_list entries in
              if entries <> [] then (
                List.iter (fun e -> ignore (g#aug_rm e)) entries;
                modified := true
              )
          ) xen_modules
      ) variables;
      if !modified then g#aug_save ()
    );

  and unconfigure_vbox () =
    (* Uninstall VirtualBox Guest Additions. *)
    let package_name = "virtualbox-guest-additions" in
    let has_guest_additions =
      List.exists (
        fun { G.app2_name = name } -> name = package_name
      ) apps in
    if has_guest_additions then
      Lib_linux.remove verbose g inspect [package_name];

    (* Guest Additions might have been installed from a tarball.  The
     * above code won't detect this case.  Look for the uninstall tool
     * and try running it.
     *
     * Note that it's important we do this early in the conversion
     * process, as this uninstallation script naively overwrites
     * configuration files with versions it cached prior to
     * installation.
     *)
    let vboxconfig = "/var/lib/VBoxGuestAdditions/config" in
    if g#is_file ~followsymlinks:true vboxconfig then (
      let lines = g#read_lines vboxconfig in
      let lines = Array.to_list lines in
      let rex = Str.regexp "^INSTALL_DIR=\\(.*\\)$" in
      let lines = filter_map (
        fun line ->
          if Str.string_match rex line 0 then (
            let vboxuninstall = Str.matched_group 1 line ^ "/uninstall.sh" in
            Some vboxuninstall
          )
          else None
      ) lines in
      let lines = List.filter (g#is_file ~followsymlinks:true) lines in
      match lines with
      | [] -> ()
      | vboxuninstall :: _ ->
        try
          ignore (g#command [| vboxuninstall |]);

          (* Reload Augeas to detect changes made by vbox tools uninst. *)
          Lib_linux.augeas_reload verbose g
        with
          G.Error msg ->
            warning ~prog (f_"VirtualBox Guest Additions were detected, but uninstallation failed.  The error message was: %s (ignored)")
              msg
    )

  and unconfigure_vmware () =
    (* Look for any configured VMware yum repos and disable them. *)
    let repos =
      g#aug_match "/files/etc/yum.repos.d/*/*[baseurl =~ regexp('https?://([^/]+\\.)?vmware\\.com/.*')]" in
    let repos = Array.to_list repos in
    List.iter (
      fun repo ->
        g#aug_set (repo ^ "/enabled") "0";
        g#aug_save ()
    ) repos;

    (* Uninstall VMware Tools. *)
    let remove = ref [] and libraries = ref [] in
    List.iter (
      fun { G.app2_name = name } ->
        if name = "open-vm-tools" then
          remove := name :: !remove
        else if string_prefix name "vmware-tools-libraries-" then
          libraries := name :: !libraries
        else if string_prefix name "vmware-tools-" then
          remove := name :: !remove
    ) apps;
    let libraries = !libraries in

    (* VMware tools includes 'libraries' packages which provide custom
     * versions of core functionality. We need to install non-custom
     * versions of everything provided by these packages before
     * attempting to uninstall them, or we'll hit dependency
     * issues.
     *)
    if libraries <> [] then (
      (* We only support removal of libraries on systems which use yum. *)
      if package_management = "yum" then (
        List.iter (
          fun library ->
            let provides =
              g#command_lines [| "rpm"; "-q"; "--provides"; library |] in
            let provides = Array.to_list provides in

            (* The packages provide themselves, filter this out. *)
            let provides =
              List.filter (fun s -> string_find s library = -1) provides in

            (* Trim whitespace. *)
            let rex = Str.regexp "^[ \\t]*\\([^ \\t]+\\)[ \\t]*$" in
            let provides = List.map (Str.replace_first rex "\\1") provides in

            (* Install the dependencies with yum.  Use yum explicitly
             * because we don't have package names and local install is
             * impractical.  - RWMJ: Not convinced the original Perl code
             * would work, so I'm just installing the dependencies.
             *)
            let cmd = [ "yum"; "install"; "-y" ] @ provides in
            let cmd = Array.of_list cmd in
            (try
               ignore (g#command cmd);
               remove := library :: !remove
             with G.Error msg ->
               eprintf "%s: could not install replacement for %s.  Error was: %s.  %s was not removed.\n"
                 prog library msg library
            );
        ) libraries
      )
    );

    let remove = !remove in
    Lib_linux.remove verbose g inspect remove;

    (* VMware Tools may have been installed from a tarball, so the
     * above code won't remove it.  Look for the uninstall tool and run
     * if present.
     *)
    let uninstaller = "/usr/bin/vmware-uninstall-tools.pl" in
    if g#is_file ~followsymlinks:true uninstaller then (
      try
        ignore (g#command [| uninstaller |]);

        (* Reload Augeas to detect changes made by vbox tools uninst. *)
        Lib_linux.augeas_reload verbose g
      with
        G.Error msg ->
          warning ~prog (f_"VMware tools was detected, but uninstallation failed.  The error message was: %s (ignored)")
            msg
    )

  and unconfigure_citrix () =
    let pkgs =
      List.filter (
        fun { G.app2_name = name } -> string_prefix name "xe-guest-utilities"
      ) apps in
    let pkgs = List.map (fun { G.app2_name = name } -> name) pkgs in

    if pkgs <> [] then (
      Lib_linux.remove verbose g inspect pkgs;

      (* Installing these guest utilities automatically unconfigures
       * ttys in /etc/inittab if the system uses it. We need to put
       * them back.
       *)
      let rex = Str.regexp "^\\([1-6]\\):\\([2-5]+\\):respawn:\\(.*\\)" in
      let updated = ref false in
      let rec loop () =
        let comments = g#aug_match "/files/etc/inittab/#comment" in
        let comments = Array.to_list comments in
        match comments with
        | [] -> ()
        | commentp :: _ ->
          let comment = g#aug_get commentp in
          if Str.string_match rex comment 0 then (
            let name = Str.matched_group 1 comment in
            let runlevels = Str.matched_group 2 comment in
            let process = Str.matched_group 3 comment in

            if string_find process "getty" >= 0 then (
              updated := true;

              (* Create a new entry immediately after the comment. *)
              g#aug_insert commentp name false;
              g#aug_set ("/files/etc/inittab/" ^ name ^ "/runlevels") runlevels;
              g#aug_set ("/files/etc/inittab/" ^ name ^ "/action") "respawn";
              g#aug_set ("/files/etc/inittab/" ^ name ^ "/process") process;

              (* Delete the comment node. *)
              ignore (g#aug_rm commentp);

              (* As the aug_rm invalidates the output of aug_match, we
               * now have to restart the whole loop.
               *)
              loop ()
            )
          )
      in
      loop ();
      if !updated then g#aug_save ();
    )

  and unconfigure_efi () =
    match efi with
    | None -> ()
    | Some dev ->
      match grub with
      | `Grub1 ->
        g#cp "/etc/grub.conf" "/boot/grub/grub.conf";
        g#ln_sf "/boot/grub/grub.conf" "/etc/grub.conf";

        (* Reload Augeas to pick up new location of grub.conf. *)
        Lib_linux.augeas_reload verbose g;

        ignore (g#command [| "grub-install"; dev |])

      | `Grub2 ->
        (* EFI systems boot using grub2-efi, and probably don't have the
         * base grub2 package installed.
         *)
        Lib_linux.install verbose g inspect ["grub2"];

        (* Relabel the EFI boot partition as a BIOS boot partition. *)
        g#part_set_gpt_type dev 1 "21686148-6449-6E6F-744E-656564454649";

        (* Delete the fstab entry for the EFI boot partition. *)
        let nodes = g#aug_match "/files/etc/fstab/*[file = '/boot/efi']" in
        let nodes = Array.to_list nodes in
        List.iter (fun node -> ignore (g#aug_rm node)) nodes;
        g#aug_save ();

        (* Install grub2 in the BIOS boot partition. This overwrites the
         * previous contents of the EFI boot partition.
         *)
        ignore (g#command [| "grub2-install"; dev |]);

        (* Re-generate the grub2 config, and put it in the correct place *)
        ignore (g#command [| "grub2-mkconfig"; "-o"; "/boot/grub2/grub.cfg" |])

  and configure_kernel () =
    (* Previously this function would try to install kernels, but we
     * don't do that any longer.
     *)

    (* Check a non-Xen kernel exists. *)
    let only_xen_kernels = List.for_all (
      fun { ki_is_xen_kernel = is_xen_kernel } -> is_xen_kernel
    ) grub_kernels in
    if only_xen_kernels then
      error (f_"only Xen kernels are installed in this guest.\n\nRead the %s(1) manual, section \"XEN PARAVIRTUALIZED GUESTS\", to see what to do.") prog;

    (* Enable the best non-Xen kernel, where "best" means the one with
     * the highest version which supports virtio.
     *)
    let best_kernel =
      let compare_best_kernels k1 k2 =
        let i = compare k1.ki_supports_virtio k2.ki_supports_virtio in
        if i <> 0 then i
        else compare_app2_versions k1.ki_app k2.ki_app
      in
      let kernels = grub_kernels in
      let kernels = List.filter (fun { ki_is_xen_kernel = is_xen_kernel } -> not is_xen_kernel) kernels in
      let kernels = List.sort compare_best_kernels kernels in
      let kernels = List.rev kernels (* so best is first *) in
      List.hd kernels in
    if best_kernel <> List.hd grub_kernels then
      grub_set_bootable best_kernel;

    rebuild_initrd best_kernel;

    (* Does the best/bootable kernel support virtio? *)
    best_kernel.ki_supports_virtio

  and grub_set_bootable kernel =
    let cmd =
      if g#exists "/sbin/grubby" then
        [| "grubby"; "--set-kernel"; kernel.ki_vmlinuz |]
      else
        [| "/usr/bin/perl"; "-MBootloader::Tools"; "-e"; sprintf "
              InitLibrary();
              my @sections = GetSectionList(type=>image, image=>\"%s\");
              my $section = GetSection(@sections);
              my $newdefault = $section->{name};
              SetGlobals(default, \"$newdefault\");
            " kernel.ki_vmlinuz |] in
    ignore (g#command cmd)

  (* Even though the kernel was already installed (this version of
   * virt-v2v does not install new kernels), it could have an
   * initrd that does not have support virtio.  Therefore rebuild
   * the initrd.
   *)
  and rebuild_initrd kernel =
    match kernel.ki_initrd with
    | None -> ()
    | Some initrd ->
      let virtio = kernel.ki_supports_virtio in
      let modules =
        if virtio then
          (* The order of modules here is deliberately the same as the
           * order specified in the postinstall script of kmod-virtio in
           * RHEL3. The reason is that the probing order determines the
           * major number of vdX block devices. If we change it, RHEL 3
           * KVM guests won't boot.
           *)
          [ "virtio"; "virtio_ring"; "virtio_blk"; "virtio_net";
            "virtio_pci" ]
        else
          [ "sym53c8xx" (* XXX why not "ide"? *) ] in

      (* Move the old initrd file out of the way.  Note that dracut/mkinitrd
       * will refuse to overwrite an old file so we have to do this.
       *)
      g#mv initrd (initrd ^ ".pre-v2v");

      if g#is_file ~followsymlinks:true "/sbin/dracut" then (
        (* Dracut. *)
        ignore (
          g#command [| "/sbin/dracut";
                       "--add-drivers"; String.concat " " modules;
                       initrd; kernel.ki_version |]
        )
      )
      else if family = `SUSE_family
           && g#is_file ~followsymlinks:true "/sbin/mkinitrd" then (
        ignore (
          g#command [| "/sbin/mkinitrd";
                       "-m"; String.concat " " modules;
                       "-i"; initrd;
                       "-k"; kernel.ki_vmlinuz |]
        )
      )
      else if g#is_file ~followsymlinks:true "/sbin/mkinitrd" then (
        let module_args = List.map (sprintf "--with=%s") modules in
        let args =
          [ "/sbin/mkinitrd" ] @ module_args @ [ initrd; kernel.ki_version ] in

        (* We explicitly modprobe ext2 here. This is required by
         * mkinitrd on RHEL 3, and shouldn't hurt on other OSs. We
         * don't care if this fails.
         *)
        (try g#modprobe "ext2" with G.Error _ -> ());

        (* loop is a module in RHEL 5. Try to load it. Doesn't matter
         * for other OSs if it doesn't exist, but RHEL 5 will complain:
         *   "All of your loopback devices are in use."
         *
         * XXX RHEL 3 unfortunately will give this error anyway.
         * mkinitrd runs the nash command `findlodev' which is
         * essentially incompatible with modern kernels that don't
         * have fixed /dev/loopN devices.
         *)
        (try g#modprobe "loop" with G.Error _ -> ());

        (* RHEL 4 mkinitrd determines if the root filesystem is on LVM
         * by checking if the device name (after following symlinks)
         * starts with /dev/mapper. However, on recent kernels/udevs,
         * /dev/mapper/foo is just a symlink to /dev/dm-X. This means
         * that RHEL 4 mkinitrd running in the appliance fails to
         * detect root on LVM. We check ourselves if root is on LVM,
         * and frig RHEL 4's mkinitrd if it is by setting root_lvm=1 in
         * its environment. This overrides an internal variable in
         * mkinitrd, and is therefore extremely nasty and applicable
         * only to a particular version of mkinitrd.
         *)
        let env =
          if family = `RHEL_family && major_version = 4 then
            Some "root_lvm=1"
          else
            None in

        match env with
        | None -> ignore (g#command (Array.of_list args))
        | Some env ->
          let cmd = sprintf "sh -c '%s %s'" env (String.concat " " args) in
          ignore (g#sh cmd)
      )
      else (
        error (f_"unable to rebuild initrd (%s) because mkinitrd or dracut was not found in the guest")
          initrd
      )

  (* We configure a console on ttyS0. Make sure existing console
   * references use it.  N.B. Note that the RHEL 6 xen guest kernel
   * presents a console device called /dev/hvc0, whereas previous xen
   * guest kernels presented /dev/xvc0. The regular kernel running
   * under KVM also presents a virtio console device called /dev/hvc0,
   * so ideally we would just leave it alone. However, RHEL 6 libvirt
   * doesn't yet support this device so we can't attach to it. We
   * therefore use /dev/ttyS0 for RHEL 6 anyway.
   *)
  and configure_console () =
    (* Look for gettys using xvc0 or hvc0.  RHEL 6 doesn't use inittab
     * but this still works.
     *)
    let paths = g#aug_match "/files/etc/inittab/*/process" in
    let paths = Array.to_list paths in
    let rex = Str.regexp "\\(.*\\)\\b\\([xh]vc0\\)\\b\\(.*\\)" in
    List.iter (
      fun path ->
        let proc = g#aug_get path in
        if Str.string_match rex proc 0 then (
          let proc = Str.global_replace rex "\\1ttyS0\\3" proc in
          g#aug_set path proc
        );
    ) paths;

    let paths = g#aug_match "/files/etc/securetty/*" in
    let paths = Array.to_list paths in
    List.iter (
      fun path ->
        let tty = g#aug_get path in
        if tty = "xvc0" || tty = "hvc0" then
          g#aug_set path "ttyS0"
    ) paths;

    g#aug_save ()

  and grub_configure_console () =
    match grub with
    | `Grub1 ->
      let rex = Str.regexp "\\(.*\\)\\b\\([xh]vc0\\)\\b\\(.*\\)" in
      let expr = sprintf "/files%s/title/kernel/console" grub_config in

      let paths = g#aug_match expr in
      let paths = Array.to_list paths in
      List.iter (
        fun path ->
          let console = g#aug_get path in
          if Str.string_match rex console 0 then (
            let console = Str.global_replace rex "\\1ttyS0\\3" console in
            g#aug_set path console
          )
      ) paths;

      g#aug_save ()

    | `Grub2 ->
      grub2_update_console ~remove:false

  (* If the target doesn't support a serial console, we want to remove
   * all references to it instead.
   *)
  and remove_console () =
    (* Look for gettys using xvc0 or hvc0.  RHEL 6 doesn't use inittab
     * but this still works.
     *)
    let paths = g#aug_match "/files/etc/inittab/*/process" in
    let paths = Array.to_list paths in
    let rex = Str.regexp ".*\\b\\([xh]vc0|ttyS0\\)\\b.*" in
    List.iter (
      fun path ->
        let proc = g#aug_get path in
        if Str.string_match rex proc 0 then
          ignore (g#aug_rm (path ^ "/.."))
    ) paths;

    let paths = g#aug_match "/files/etc/securetty/*" in
    let paths = Array.to_list paths in
    List.iter (
      fun path ->
        let tty = g#aug_get path in
        if tty = "xvc0" || tty = "hvc0" then
          ignore (g#aug_rm path)
    ) paths;

    g#aug_save ()

  and grub_remove_console () =
    match grub with
    | `Grub1 ->
      let rex = Str.regexp "\\(.*\\)\\b\\([xh]vc0\\)\\b\\(.*\\)" in
      let expr = sprintf "/files%s/title/kernel/console" grub_config in

      let rec loop = function
        | [] -> ()
        | path :: paths ->
          let console = g#aug_get path in
          if Str.string_match rex console 0 then (
            ignore (g#aug_rm path);
            (* All the paths are invalid, restart the loop. *)
            let paths = g#aug_match expr in
            let paths = Array.to_list paths in
            loop paths
          )
          else
            loop paths
      in
      let paths = g#aug_match expr in
      let paths = Array.to_list paths in
      loop paths;

      g#aug_save ()

    | `Grub2 ->
      grub2_update_console ~remove:true

  and grub2_update_console ~remove =
    let rex = Str.regexp "\\(.*\\)\\bconsole=[xh]vc0\\b\\(.*\\)" in

    let grub_cmdline_expr =
      if g#exists "/etc/sysconfig/grub" then
        "/files/etc/sysconfig/grub/GRUB_CMDLINE_LINUX"
      else
        "/files/etc/default/grub/GRUB_CMDLINE_LINUX_DEFAULT" in

    (try
       let grub_cmdline = g#aug_get grub_cmdline_expr in
       let grub_cmdline =
         if Str.string_match rex grub_cmdline 0 then (
           if remove then
             Str.global_replace rex "\\1\\3" grub_cmdline
           else
             Str.global_replace rex "\\1console=ttyS0\\3" grub_cmdline
         )
         else grub_cmdline in
       g#aug_set grub_cmdline_expr grub_cmdline;
       g#aug_save ();

       ignore (g#command [| "grub2-mkconfig"; "-o"; grub_config |])
     with
       G.Error msg ->
         warning ~prog (f_"could not update grub2 console: %s (ignored)")
           msg
    )

  in

  augeas_grub_configuration ();
  clean_rpmdb ();
  autorelabel ();

  unconfigure_xen ();
  unconfigure_vbox ();
  unconfigure_vmware ();
  unconfigure_citrix ();
  unconfigure_efi ();

  let virtio = configure_kernel () in

  if keep_serial_console then (
    configure_console ();
    grub_configure_console ();
  ) else (
    remove_console ();
    grub_remove_console ();
  );








  let guestcaps = {
    gcaps_block_bus = if virtio then "virtio" else "ide";
    gcaps_net_bus = if virtio then "virtio" else "e1000";
  (* XXX display *)
  } in

  guestcaps