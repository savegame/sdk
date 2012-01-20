#!/usr/bin/python
# Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.

"""This is the entry point to create Dart APIs from the IDL database."""

import dartgenerator
import database
import logging.config
import os
import shutil
import sys

DOM_LIBRARY = 'dom.dart'
DOM_DEFAULT_LIBRARY = 'wrapping_dom.dart'

_logger = logging.getLogger('dartdomgenerator')

_webkit_renames = {
    # W3C -> WebKit name conversion
    # TODO(vsm): Maybe Store these renames in the IDLs.
    'ApplicationCache': 'DOMApplicationCache',
    'BarProp': 'BarInfo',
    'DedicatedWorkerGlobalScope': 'DedicatedWorkerContext',
    'FormData': 'DOMFormData',
    'Selection': 'DOMSelection',
    'SharedWorkerGlobalScope': 'SharedWorkerContext',
    'Window': 'DOMWindow',
    'WorkerGlobalScope': 'WorkerContext'}

_webkit_renames_inverse = dict((v,k) for k, v in _webkit_renames.iteritems())

def GenerateDOM(output_dir):
  # TODO(sra): Make this entry point also generate HTML.
  current_dir = os.path.dirname(__file__)

  generator = dartgenerator.DartGenerator(
      auxiliary_dir=os.path.join(current_dir, '..', 'src'),
      template_dir=os.path.join(current_dir, '..', 'templates'),
      base_package='')
  generator.LoadAuxiliary()

  common_database = database.Database(
      os.path.join(current_dir, '..', 'database'))
  common_database.Load()
  # Remove these types since they are mapped directly to dart.
  common_database.DeleteInterface('DOMStringMap')
  common_database.DeleteInterface('DOMStringList')
  generator.RenameTypes(common_database, {
      # W3C -> Dart renames
      'AbstractView': 'Window',
      'Function': 'EventListener',
      'DOMStringMap': 'Map<String, String>',
      'DOMStringList': 'List<String>',
      })
  generator.FilterMembersWithUnidentifiedTypes(common_database)
  generator.ConvertToDartTypes(common_database)
  webkit_database = common_database.Clone()

  generated_output_dir = os.path.join(output_dir, 'generated')
  if os.path.exists(generated_output_dir):
    _logger.info('Cleaning output directory %s' % generated_output_dir)
    shutil.rmtree(generated_output_dir)


  # Generate Dart interfaces for the WebKit DOM.
  webkit_output_dir = generated_output_dir
  generator.FilterInterfaces(database = webkit_database,
                             or_annotations = ['WebKit', 'Dart'],
                             exclude_displaced = ['WebKit'],
                             exclude_suppressed = ['WebKit', 'Dart'])
  generator.RenameTypes(webkit_database, _webkit_renames)

  generator.Generate(database = webkit_database,
                     output_dir = webkit_output_dir,
                     lib_dir = output_dir,
                     module_source_preference = ['WebKit', 'Dart'],
                     source_filter = ['WebKit', 'Dart'],
                     super_database = common_database,
                     common_prefix = 'common',
                     super_map = _webkit_renames_inverse)

  generator.Flush()

  # Install default DOM library.
  default = os.path.join(output_dir, DOM_DEFAULT_LIBRARY)
  target = os.path.join(output_dir, DOM_LIBRARY)
  shutil.copyfile(default, target)

def main():
  current_dir = os.path.dirname(__file__)
  logging.config.fileConfig(os.path.join(current_dir, 'logging.conf'))
  GenerateDOM(os.path.join(current_dir, '..'))

if __name__ == '__main__':
  sys.exit(main())
