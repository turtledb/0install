0install
========

Copyright Thomas Leonard and others, 2013

INTRODUCTION
------------

Zero Install is a decentralised cross-distribution software installation system
available under the LGPL. It allows software developers to publish programs
directly from their own web-sites, while supporting features familiar from
centralised distribution repositories such as shared libraries, automatic
updates and digital signatures. It is intended to complement, rather than
replace, the operating system's package management. 0install packages never
interfere with those provided by the distribution.

0install does not define a new packaging format; unmodified tarballs or zip
archives can be used. Instead, it defines an XML metadata format to describe
these packages and the dependencies between them. A single metadata file can be
used on multiple platforms (e.g. Ubuntu, Debian, Fedora, openSUSE, Mac OS X and
Windows), assuming binary or source archives are available that work on those
systems.

0install also has some interesting features not often found in traditional
package managers. For example, while it will share libraries whenever possible,
it can always install multiple versions of a package in parallel when there are
conflicting requirements. Installation is always side-effect-free (each package
is unpacked to its own directory and will not touch shared directories such as
/usr/bin), making it ideal for use with sandboxing technologies and
virtualisation.

The XML file describing the program's requirements can also be included in a
source-code repository, allowing full dependency handling for unreleased
developer versions. For example, a user can clone a Git repository and build
and test the program, automatically downloading newer versions of libraries
where necessary, without interfering with the versions of those libraries
installed by their distribution, which continue to be used for other software.

See [the 0install.net web-site](http://0install.net/) for full details.


INSTALLATION
------------

0install is written in a mixture of Python and OCaml. You will need the OCaml
build tools and some OCaml libraries to compile 0install.

The easiest way to get the dependencies is using [OPAM](http://opam.ocamlpro.com/):

    $ opam sw 4.01.0
    $ eval `opam config env`
    $ opam install yojson xmlm ounit lwt extlib ssl ocurl obus lablgtk

(obus and lablgtk are optional. obus is used on Linux to add support for D-BUS notifications,
installing native packages using PackageKit, and using NetworkManager to check
the network status before doing background updates. lablgtk provides a GTK GUI.)

Alternatively, you can use your distribution's packages if you prefer (and if
they are new enough). For example, on Debian:

    $ sudo apt-get install gettext ocaml-nox ocaml-findlib libyojson-ocaml-dev \
       libxmlm-ocaml-dev camlp4-extra make liblwt-ocaml-dev libounit-ocaml-dev \
       python-gobject libextlib-ocaml-dev libcurl-ocaml-dev libssl-ocaml-dev \
       libobus-ocaml-dev liblablgtk2-ocaml-dev liblwt-glib-ocaml-dev

Either way, build and install by running this command in the top-level directory:

    $ make && sudo make install

You can also install just to your home directory (this doesn't require root
access):

    $ make && make install_home
    $ export PATH=$HOME/bin:$PATH

Logging out and back in again will ensure $PATH and the Applications menu get
updated correctly, on Ubuntu at least.

To try 0install without installing:

    $ make
    $ ./dist/files/0install --help

### Windows installation

A Windows binary of 0install is available at [0install.de](http://0install.de/?lang=en).

Warning: I know very little about Windows. These instructions are the result of many hours of random trial-and-error and Google searches. Please help improve things here if you can.

If you want to compile from source on Windows you'll need to install quite a few things manually:

- [OCaml 4.0.1 Windows Installer](http://protz.github.io/ocaml-installer/)
- [Cygwin](http://www.cygwin.com/) and various of its packages: mingw64-i686-gcc-core, mingw-i686-headers and make, at least (make sure /cygdrive/c/MinGW/bin is in $PATH)
- [Xmlm](http://erratique.ch/software/xmlm)
- [Yojson] (http://mjambon.com/yojson.html) (and its dependencies: Cppo, Easy-format, Biniou)
- [Lwt](http://ocsigen.org/lwt/) (and its dependency React). You'll also need to apply [this EPIPE fix](https://github.com/ocsigen/lwt/issues/20)
- [extlib](http://code.google.com/p/ocaml-extlib/) - if you get "ocamlfind: extLib.lib: No such file or directory", modify install.ml to use the "Unix" extensions for "Win32" too.
- [openssl](http://www.openssl.org/)
  1. Use `cp -Lr openssl copy` to turn all symlinks into regular files.
  2. `perl Configure mingw shared --prefix=C:/OCaml` in `copy`.
  3. `cp -Lr copy copy2` to turn all symlinks into regular files again.
  4. `make` and `make install` inside `copy2`.
- [ocaml-ssl](http://sourceforge.net/projects/savonet/files/ocaml-ssl/) - use `./configure LDFLAGS=-LC:/OCaml/lib CFLAGS=-IC:/OCaml/include`.
- [libcurl](http://curl.haxx.se/download.html):
  1. Edit each Makefile.m32 to say `OPENSSL_PATH = c:/OCaml`.
  2. Build with `mingw32-make.exe mingw32-ssl`.
  3. Copy `lib/libcurl.a` to `c:/OCaml/lib`.
- [ocurl](http://sourceforge.net/projects/ocurl/) - these steps worked for me:
  1. There's no curl-config, so edit `configure` to use:

             CURLDIR=-Ic:/OCaml/lib
             CURLFLAGS="-lcurl -ccopt -lssl -ccopt -lcrypto -ccopt -lwldap32"
             CURLLIBS=

             CFLAGS="$CURLDIR -DCURL_STATICLIB -Ic:/OCaml/include"
  2. `./configure`
  3. Edit Makefile to set `FINDLIB = ocamlfind`.
  4. `curl.h` seems to redefine `interface`, so rename all ocurrances in `curl-helper.c` to `interface_`.
  5. `make` and `make install`.

Then, to build 0install under Cygwin:

    cd ocaml
    make ocaml

This creates the executables build/ocaml/install.exe and build/ocaml/0install-runenv.exe.
If you'd like to make the top-level Makefile work on Windows so you can "make install", please
send a patch.


TAB COMPLETION
--------------

A bash completion script is available in share/bash-completion. It can be
sourced from your .bashrc or added under /usr/share/bash-completion. Note that
you may have to install a separate "bash-completion" package on some systems.

For zsh users, copy the script in share/zsh/site-functions/ to a directory in
your $fpath (e.g. /usr/local/share/zsh/site-functions).

For fish-shell users, add the full path to share/fish/completions to
$fish_complete_path.

These completion scripts are installed automatically by "make install".


QUICK START
-----------

To install [Edit](http://rox.sourceforge.net/2005/interfaces/Edit) and name it 'rox-edit':

    $ 0install add rox-edit http://rox.sourceforge.net/2005/interfaces/Edit

To run it (use the name you chose above):

    $ rox-edit

When you run it, 0install will check how long it has been since it checked
for updates and will run a check in the background if it has been too long.
To check for updates manually:

    $ 0install update rox-edit
    http://rox.sourceforge.net/2005/interfaces/ROX-Lib: 2.0.5 -> 2.0.6

This shows that ROX-Lib, a library rox-edit uses, was upgraded.

If an upgrade stops a program from working, use "0install whatchanged".
This will tell you when the application was last upgraded and what changed, and
tell you how to revert to the previous version:

    $ 0install whatchanged rox-edit
    Last checked    : Tue Sep 25 09:45:19 2012
    Last update     : 2012-09-25
    Previous update : 2012-08-25
    
    http://rox.sourceforge.net/2005/interfaces/ROX-Lib: 2.0.5 -> 2.0.6
    
    To run using the previous selections, use:
    0install run /home/tal/.config/0install.net/apps/rox-edit/selections-2012-08-25.xml

To see where things have been stored:

    $ 0install show rox-edit
    - URI: http://rox.sourceforge.net/2005/interfaces/Edit
      Version: 2.2
      Path: /home/tal/.cache/0install.net/implementations/sha256=ba3b4953...c8ce3177f08c926bebafcf16b9
      - URI: http://rox.sourceforge.net/2005/interfaces/ROX-Lib
        Version: 2.0.6
        Path: /home/tal/.cache/0install.net/implementations/sha256=ccefa7b187...16b6d0ad67c4df6d0c06243e
      - URI: http://repo.roscidus.com/python/python
        Version: 2.7.3-4
        Path: (package:deb:python2.7:2.7.3-4:x86_64)

To view or change configuration settings:

    $ 0install config

For more information, see the man-page for 0install and [the 0install.net web-site](http://0install.net/).


CONDITIONS
----------

This library is free software; you can redistribute it and/or
modify it under the terms of the GNU Lesser General Public
License as published by the Free Software Foundation; either
version 2.1 of the License, or (at your option) any later version.

This library is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public
License along with this library; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA


BUG REPORTS
-----------

Please report any bugs to [the mailing list](http://0install.net/support.html).
