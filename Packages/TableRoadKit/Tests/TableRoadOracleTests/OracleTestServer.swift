import Darwin
import Foundation
import TableRoadCore
import TableRoadSQL

@testable import TableRoadOracle

/// docker/compose.yml runs Oracle Database Free on 11521 (service FREEPDB1, user tableroad/tableroad, SYSTEM password
/// tableroad).
enum OracleTestServer {
    static let port = 11521
    static let endpoint = OracleEndpoint(host: "127.0.0.1", port: port, serviceName: "FREEPDB1", useTLS: false)
    static let config = OracleConnectConfig(
        host: "127.0.0.1", port: port, username: "tableroad", password: "tableroad", serviceName: "FREEPDB1")
    static let systemConfig = OracleConnectConfig(
        host: "127.0.0.1", port: port, username: "system", password: "tableroad", serviceName: "FREEPDB1")

    static let available: Bool = {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }()

    @Sendable static func connect() async throws -> any SQLClient { try await OracleSession.connect(config) }

    /// Creates the test schema objects (dropping earlier copies first): every column type, a primary key, a foreign
    /// key, an index, a view and a 1,000-row table.
    static func prepare(_ session: OracleSession) async throws {
        for table in ["TR_TYPES", "TR_AUTHORS", "TR_BIG", "TR_LONG", "TR_DDL"] {
            try await session.run(
                """
                BEGIN
                  EXECUTE IMMEDIATE 'DROP TABLE \(table) CASCADE CONSTRAINTS PURGE';
                EXCEPTION WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
                END;
                /
                """)
        }
        try await session.run(
            """
            CREATE TABLE tr_authors (id NUMBER(10) PRIMARY KEY, name VARCHAR2(100) NOT NULL);
            CREATE TABLE tr_types (
              id NUMBER(10) PRIMARY KEY,
              author_id NUMBER(10) CONSTRAINT tr_types_author_fk REFERENCES tr_authors(id) ON DELETE CASCADE,
              num_int NUMBER(10), num_dec NUMBER(12,4), num_any NUMBER, num_float FLOAT(53),
              bf BINARY_FLOAT, bd BINARY_DOUBLE,
              vc VARCHAR2(100 CHAR), nvc NVARCHAR2(50), ch CHAR(5), nch NCHAR(5),
              dt DATE, ts TIMESTAMP(6), tstz TIMESTAMP(6) WITH TIME ZONE, tsltz TIMESTAMP WITH LOCAL TIME ZONE,
              iym INTERVAL YEAR(2) TO MONTH, ids INTERVAL DAY(2) TO SECOND(6),
              rw RAW(16), cl CLOB, ncl NCLOB, bl BLOB, flag BOOLEAN
            );
            CREATE INDEX tr_types_author_ix ON tr_types(author_id);
            COMMENT ON TABLE tr_types IS 'Every type';
            COMMENT ON COLUMN tr_types.vc IS 'Some text';
            CREATE OR REPLACE VIEW tr_types_view AS SELECT id, vc FROM tr_types;
            CREATE TABLE tr_big (id NUMBER PRIMARY KEY, label VARCHAR2(40));
            INSERT INTO tr_big SELECT level, 'row ' || level FROM dual CONNECT BY level <= 1000;
            CREATE TABLE tr_long (id NUMBER PRIMARY KEY, body LONG);
            INSERT INTO tr_authors VALUES (1, 'Le Guin');
            INSERT INTO tr_authors VALUES (2, 'Banks');
            INSERT INTO tr_types (id, author_id, num_int, num_dec, num_any, num_float, bf, bd, vc, nvc, ch, nch, dt, ts,
              tstz, tsltz, iym, ids, rw, cl, ncl, bl, flag)
            VALUES (1, 1, -42, 12345.6789, 0.000123, 1.5, 1.5, -2.25, 'héllo ☃', N'ünï ☃', 'ab', N'xy',
              TIMESTAMP '2024-02-29 13:14:15', TIMESTAMP '2024-02-29 13:14:15.123456',
              TIMESTAMP '2024-02-29 13:14:15.5 +05:30', TIMESTAMP '2024-02-29 13:14:15',
              INTERVAL '1-2' YEAR TO MONTH, INTERVAL '3 04:05:06.789' DAY TO SECOND, HEXTORAW('DEADBEEF'),
              'clob text ☃', N'nclob ☃', HEXTORAW('00FF10'), TRUE);
            INSERT INTO tr_types (id) VALUES (2);
            INSERT INTO tr_long VALUES (1, 'long text');
            """)
    }
}
