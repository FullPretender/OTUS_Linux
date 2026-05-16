<?php
/**
 * Plugin Name: Demo Forum
 * Description: Lightweight forum board for the OTUS Linux diploma demo.
 * Version: 1.0.0
 * Author: OTUS Linux
 */

if ( ! defined( 'ABSPATH' ) ) {
    exit;
}

function demo_forum_register_message_type() {
    register_post_type(
        'demo_forum_message',
        array(
            'labels' => array(
                'name'          => 'Forum Messages',
                'singular_name' => 'Forum Message',
            ),
            'public'       => false,
            'show_ui'      => true,
            'supports'     => array( 'title', 'editor' ),
            'show_in_rest' => true,
        )
    );
}
add_action( 'init', 'demo_forum_register_message_type' );

function demo_forum_handle_submission() {
    if ( ! isset( $_POST['demo_forum_nonce'] ) || ! wp_verify_nonce( sanitize_text_field( wp_unslash( $_POST['demo_forum_nonce'] ) ), 'demo_forum_submit' ) ) {
        return;
    }

    $author  = isset( $_POST['demo_forum_author'] ) ? sanitize_text_field( wp_unslash( $_POST['demo_forum_author'] ) ) : '';
    $title   = isset( $_POST['demo_forum_title'] ) ? sanitize_text_field( wp_unslash( $_POST['demo_forum_title'] ) ) : '';
    $message = isset( $_POST['demo_forum_message'] ) ? sanitize_textarea_field( wp_unslash( $_POST['demo_forum_message'] ) ) : '';

    if ( '' === $author || '' === $title || '' === $message ) {
        return;
    }

    wp_insert_post(
        array(
            'post_type'    => 'demo_forum_message',
            'post_status'  => 'publish',
            'post_title'   => $title,
            'post_content' => $message,
            'post_author'  => 1,
            'meta_input'   => array(
                'demo_forum_author' => $author,
            ),
        )
    );

    wp_safe_redirect( add_query_arg( 'message', 'added', wp_get_referer() ? wp_get_referer() : home_url( '/' ) ) );
    exit;
}
add_action( 'template_redirect', 'demo_forum_handle_submission' );

function demo_forum_shortcode() {
    $messages = new WP_Query(
        array(
            'post_type'      => 'demo_forum_message',
            'post_status'    => 'publish',
            'posts_per_page' => 10,
            'orderby'        => 'date',
            'order'          => 'DESC',
        )
    );

    ob_start();
    ?>
    <section class="demo-forum">
        <?php if ( isset( $_GET['message'] ) && 'added' === $_GET['message'] ) : ?>
            <div class="demo-forum-notice">Сообщение добавлено в форум.</div>
        <?php endif; ?>

        <div class="demo-forum-grid">
            <div class="demo-forum-list">
                <h2>Последние обсуждения</h2>
                <?php if ( $messages->have_posts() ) : ?>
                    <?php while ( $messages->have_posts() ) : $messages->the_post(); ?>
                        <article class="demo-forum-card">
                            <h3><?php the_title(); ?></h3>
                            <p><?php echo esc_html( get_the_content() ); ?></p>
                            <span>
                                <?php echo esc_html( get_post_meta( get_the_ID(), 'demo_forum_author', true ) ); ?>
                                · <?php echo esc_html( get_the_date( 'd.m.Y H:i' ) ); ?>
                            </span>
                        </article>
                    <?php endwhile; ?>
                    <?php wp_reset_postdata(); ?>
                <?php else : ?>
                    <p>Пока нет сообщений. Добавьте первое обсуждение.</p>
                <?php endif; ?>
            </div>

            <form class="demo-forum-form" method="post">
                <h2>Добавить сообщение</h2>
                <?php wp_nonce_field( 'demo_forum_submit', 'demo_forum_nonce' ); ?>
                <label>
                    Имя
                    <input type="text" name="demo_forum_author" required>
                </label>
                <label>
                    Тема
                    <input type="text" name="demo_forum_title" required>
                </label>
                <label>
                    Сообщение
                    <textarea name="demo_forum_message" rows="6" required></textarea>
                </label>
                <button type="submit">Опубликовать</button>
            </form>
        </div>
    </section>
    <?php

    return ob_get_clean();
}
add_shortcode( 'demo_forum', 'demo_forum_shortcode' );
