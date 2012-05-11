"""
Support for managing apps (as created with "0install add").
@since: 1.8
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, SafeException
from zeroinstall.support import basedir
from zeroinstall.injector import namespaces, selections, qdom
from logging import warn
import re, os, time

# Avoid characters that are likely to cause problems (reject : and ; everywhere
# so that apps can be portable between POSIX and Windows).
valid_name = re.compile(r'''^[^./\\:=;'"][^/\\:=;'"]*$''')

def validate_name(name):
	if valid_name.match(name): return
	raise SafeException("Invalid application name '{name}'".format(name = name))

def find_bin_dir(paths = None):
	"""Find the first writable path in the list (default $PATH),
	skipping /bin, /sbin and everything under /usr except /usr/local/bin"""
	if paths is None:
		paths = os.environ['PATH'].split(os.pathsep)
	for path in paths:
		if path.startswith('/usr/') and not path.startswith('/usr/local/bin'):
			# (/usr/local/bin is OK if we're running as root)
			pass
		elif path.startswith('/bin') or path.startswith('/sbin'):
			pass
		elif os.path.realpath(path).startswith(basedir.xdg_cache_home):
			pass # print "Skipping cache", first_path
		elif not os.access(path, os.W_OK):
			pass # print "No access", first_path
		else:
			break
	else:
		return None

	return path

_command_template = """#!/bin/sh
exec 0install run {app} "$@"
"""

class App:
	def __init__(self, config, path):
		self.config = config
		self.path = path

	def set_selections(self, sels):
		sels_file = os.path.join(self.path, 'selections.xml')
		dom = sels.toDOM()
		with open(sels_file, 'w') as stream:
			dom.writexml(stream, addindent="  ", newl="\n", encoding = 'utf-8')
		self.set_last_check()

	def get_selections(self):
		sels_file = os.path.join(self.path, 'selections.xml')
		with open(sels_file) as stream:
			sels = selections.Selections(qdom.parse(stream))

		stores = self.config.stores

		for iface, sel in sels.selections.iteritems():
			#print iface, sel
			if sel.id.startswith('package:'):
				pass		# TODO: check version is the same
			elif not sel.is_available(stores):
				print "missing", sel	# TODO: download

		# Check the selections are still available and up-to-date
		timestamp_path = os.path.join(self.path, 'last-check')
		try:
			utime = os.stat(timestamp_path).st_mtime
			#print "Staleness", time.time() - utime
			need_update = False
		except Exception as ex:
			warn("Failed to get time-stamp of %s: %s", timestamp_path, ex)
			need_update = True

		# TODO: update if need_update

		return sels

	def set_last_check(self):
		timestamp_path = os.path.join(self.path, 'last-check')
		fd = os.open(timestamp_path, os.O_WRONLY | os.O_CREAT, 0o644)
		os.close(fd)
		os.utime(timestamp_path, None)	# In case file already exists

	def destroy(self):
		# Check for shell command
		# TODO: remember which commands we own instead of guessing
		name = self.get_name()
		bin_dir = find_bin_dir()
		launcher = os.path.join(bin_dir, name)
		expanded_template = _command_template.format(app = name)
		if os.path.exists(launcher) and os.path.getsize(launcher) == len(expanded_template):
			with open(launcher, 'r') as stream:
				contents = stream.read()
			if contents == expanded_template:
				#print "rm", launcher
				os.unlink(launcher)

		# Remove the app itself
		import shutil
		shutil.rmtree(self.path)

	def integrate_shell(self, name):
		# TODO: remember which commands we create
		if not valid_name.match(name):
			raise SafeException("Invalid shell command name '{name}'".format(name = name))
		bin_dir = find_bin_dir()
		launcher = os.path.join(bin_dir, name)
		if os.path.exists(launcher):
			raise SafeException("Command already exists: {path}".format(path = launcher))

		with open(launcher, 'w') as stream:
			stream.write(_command_template.format(app = self.get_name()))
			# Make new script executable
			os.chmod(launcher, 0o111 | os.fstat(stream.fileno()).st_mode)

	def get_name(self):
		return os.path.basename(self.path)

class AppManager:
	def __init__(self, config):
		self.config = config

	def create_app(self, name):
		validate_name(name)
		apps_dir = basedir.save_config_path(namespaces.config_site, "apps")
		app_dir = os.path.join(apps_dir, name)
		if os.path.isdir(app_dir):
			raise SafeException(_("Application '{name}' already exists: {path}").format(name = name, path = app_dir))
		os.mkdir(app_dir)
		app = App(self.config, app_dir)
		app.set_last_check()
		return app

	def lookup_app(self, name, missing_ok = False):
		"""Get the App for name.
		Returns None if name is not an application (doesn't exist or is not a valid name).
		Since / and : are not valid name characters, it is generally safe to try this
		before calling L{model.canonical_iface_uri}."""
		if not valid_name.match(name):
			if missing_ok:
				return None
			else:
				raise SafeException("Invalid application name '{name}'".format(name = name))
		app_dir = basedir.load_first_config(namespaces.config_site, "apps", name)
		if app_dir:
			return App(self.config, app_dir)
		if missing_ok:
			return None
		else:
			raise SafeException("No such application '{name}'".format(name = name))
