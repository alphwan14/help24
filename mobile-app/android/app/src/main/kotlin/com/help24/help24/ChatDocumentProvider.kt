package com.help24.help24

import androidx.core.content.FileProvider

/**
 * Hands a cached chat document to a viewer app as a temporary content:// URI.
 *
 * Its own subclass so it can never collide with a FileProvider a plugin
 * declares. It is not exported; a viewer reads one file only through the
 * read grant MainActivity attaches to that one VIEW intent, and only files
 * under files/chat_documents/ (res/xml/chat_document_paths.xml) can be
 * named at all — never the rest of the app's private storage.
 */
class ChatDocumentProvider : FileProvider()
