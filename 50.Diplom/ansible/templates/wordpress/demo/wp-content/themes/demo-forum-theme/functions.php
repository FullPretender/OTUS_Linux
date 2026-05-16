<?php
if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

function demo_forum_theme_assets() {
    wp_enqueue_style( 'demo-forum-theme', get_stylesheet_uri(), array(), '1.0.0' );
}
add_action( 'wp_enqueue_scripts', 'demo_forum_theme_assets' );
