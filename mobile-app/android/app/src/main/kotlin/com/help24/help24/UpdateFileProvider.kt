package com.help24.help24

import androidx.core.content.FileProvider

/**
 * Hands Android's package installer the update the app downloaded
 * (cache/updates/, res/xml/update_paths.xml). Its own subclass and authority
 * so it never shares paths with the chat documents provider.
 */
class UpdateFileProvider : FileProvider()
