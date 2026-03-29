// @generated automatically by Diesel CLI.

diesel::table! {
    tbpps_prize_pool (id) {
        id -> Int4,
        #[max_length = 255]
        description -> Nullable<Varchar>,
        created_at -> Timestamp,
        updated_at -> Timestamp,
        #[max_length = 10]
        pool_type -> Varchar,
    }
}

diesel::table! {
    tbpps_prize_pool_award (id) {
        id -> Int4,
        seed_pool_id -> Int4,
        created_at -> Timestamp,
        award_amount -> Numeric,
    }
}

diesel::table! {
    tbpps_prize_pool_feed (id) {
        id -> Int4,
        prize_pool_id -> Int4,
        create_at -> Timestamp,
        amount -> Numeric,
    }
}

diesel::table! {
    tbpps_seed_pool (id) {
        id -> Int4,
        #[max_length = 255]
        description -> Nullable<Varchar>,
        created_at -> Timestamp,
        updated_at -> Timestamp,
        #[max_length = 10]
        pool_type -> Varchar,
        start_value -> Numeric,
    }
}

diesel::table! {
    tbpps_seed_pool_feed (id) {
        id -> Int4,
        seed_pool_id -> Int4,
        created_at -> Timestamp,
        amount -> Numeric,
    }
}

diesel::table! {
    tbpps_seed_pool_restart (id) {
        id -> Int4,
        seed_pool_id -> Int4,
        created_at -> Timestamp,
        restart_value -> Numeric,
    }
}

diesel::allow_tables_to_appear_in_same_query!(
    tbpps_prize_pool,
    tbpps_prize_pool_award,
    tbpps_prize_pool_feed,
    tbpps_seed_pool,
    tbpps_seed_pool_feed,
    tbpps_seed_pool_restart,
);
