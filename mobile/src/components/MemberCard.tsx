import React from "react";
import { StyleSheet, Text, View } from "react-native";
import { BoardItem, BoardMember } from "../lib/api";
import { formatRelative } from "../lib/time";
import { StatusPill } from "./StatusPill";
import { colors, spacing } from "../theme";

interface Props {
  /** A real member, or the synthetic "Unassigned" bucket. */
  name: string;
  kind: BoardMember["kind"] | "unassigned";
  title?: string | null;
  status?: string | null;
  items: BoardItem[];
}

/** One team member's board: who they are and what they're on. */
export const MemberCard = React.memo(function MemberCard({ name, kind, title, status, items }: Props) {
  const kindLabel = kind === "agent" ? "BOT" : kind === "human" ? "HUMAN" : "UNASSIGNED";
  return (
    <View style={styles.card}>
      <View style={styles.header}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{kind === "unassigned" ? "?" : initials(name)}</Text>
        </View>
        <View style={styles.headerBody}>
          <Text style={styles.name} numberOfLines={1}>
            {name}
          </Text>
          <Text style={styles.subtitle} numberOfLines={1}>
            {kindLabel}
            {title ? ` · ${title}` : ""}
            {status ? ` · ${status.replace(/_/g, " ")}` : ""}
          </Text>
        </View>
        <Text style={styles.count}>{items.length}</Text>
      </View>
      {items.length === 0 ? (
        <Text style={styles.empty}>Nothing on the board.</Text>
      ) : (
        items.map((item) => <ItemRow key={item.id} item={item} />)
      )}
    </View>
  );
});

function ItemRow({ item }: { item: BoardItem }) {
  return (
    <View style={styles.item}>
      <View style={styles.itemBody}>
        <Text style={styles.itemTitle} numberOfLines={2}>
          {item.key ? <Text style={styles.itemKey}>{item.key} </Text> : null}
          {item.title}
        </Text>
        <Text style={styles.itemMeta}>
          {formatRelative(item.updated_at)}
          {item.tier !== undefined ? ` · tier ${item.tier}` : ""}
          {item.priority ? ` · ${item.priority}` : ""}
        </Text>
      </View>
      <StatusPill label={item.status} />
    </View>
  );
}

function initials(name: string): string {
  return name
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? "")
    .join("");
}

const styles = StyleSheet.create({
  card: {
    backgroundColor: colors.surface,
    borderRadius: 16,
    padding: spacing.md,
    marginBottom: spacing.sm,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: spacing.sm,
  },
  avatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: colors.accentSoft,
    justifyContent: "center",
    alignItems: "center",
    marginRight: spacing.sm,
  },
  avatarText: {
    color: colors.accent,
    fontSize: 14,
    fontWeight: "700",
  },
  headerBody: {
    flex: 1,
  },
  name: {
    color: colors.text,
    fontSize: 16,
    fontWeight: "700",
  },
  subtitle: {
    color: colors.muted,
    fontSize: 12,
    marginTop: 1,
  },
  count: {
    color: colors.muted,
    fontSize: 14,
    fontWeight: "600",
    marginLeft: spacing.sm,
  },
  empty: {
    color: colors.muted,
    fontSize: 13,
  },
  item: {
    flexDirection: "row",
    alignItems: "center",
    borderTopColor: colors.border,
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingVertical: spacing.sm,
  },
  itemBody: {
    flex: 1,
    marginRight: spacing.sm,
  },
  itemTitle: {
    color: colors.text,
    fontSize: 14,
  },
  itemKey: {
    color: colors.accent,
    fontWeight: "700",
  },
  itemMeta: {
    color: colors.muted,
    fontSize: 11,
    marginTop: 2,
  },
});
