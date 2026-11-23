<?php
// static-php-cli patch script (-P) for PHP versions phpmicro has no macos_iconv patch for yet.
// Makes the same change: on macOS, iconv lives in libiconv, so configure must look there.

if (patch_point() === 'before-php-buildconf') {
    $file = SOURCE_PATH . '/php-src/build/php.m4';
    $text = file_get_contents($file);
    $old = <<<'M4'
    dnl Reset LIBS temporarily as it may have already been included -liconv in.
    LIBS_save=$LIBS
    LIBS=
    AC_CHECK_FUNC([iconv], [found_iconv=yes],
      [AC_CHECK_FUNC([libiconv], [
        AC_DEFINE([HAVE_LIBICONV], [1])
        found_iconv=yes
      ])])
    LIBS=$LIBS_save
M4;
    $new = <<<'M4'
    LIBS="$LIBS -liconv"
    AC_CHECK_FUNC([iconv], [found_iconv=yes],
      [AC_CHECK_FUNC([libiconv], [
        AC_DEFINE([HAVE_LIBICONV], [1])
        found_iconv=yes
      ])])
M4;
    if (substr_count($text, $old) !== 1) {
        throw new RuntimeException('php-macos-iconv: the iconv check in build/php.m4 has changed');
    }
    file_put_contents($file, str_replace($old, $new, $text));
}
